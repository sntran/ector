defmodule Mix.Tasks.Ector.Migrate do
  @shortdoc "Converts Ecto schemas to Ector nodes and optionally backfills data"

  @moduledoc """
  Converts standard Ecto schema modules under `lib/` to Ector nodes.

  The task writes changes by default and prints each modified path. Pass
  `--dry-run` to print the paths that would change without writing files. Pass
  `--data` to backfill existing relational rows into Ector's `nodes` and
  `edges` storage after code mutation.

      mix ector.migrate
      mix ector.migrate --dry-run
      mix ector.migrate --data --repo MyApp.Repo
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]
  import Mix.Ecto, only: [ensure_repo: 2, parse_repo: 1]

  @switches [dry_run: :boolean, data: :boolean, repo: :keep, chunk_size: :integer]
  @aliases [r: :repo]
  @migration_version 20_260_612_000_001
  @default_chunk_size 500

  @impl true
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    dry_run? = Keyword.get(opts, :dry_run, false)
    data? = Keyword.get(opts, :data, false)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    repos =
      if data? and not dry_run? do
        repos_from_options!(opts, args)
      else
        []
      end

    if data? and dry_run? do
      Mix.shell().info("Skipping data backfill because --dry-run is active")
    end

    if data? and not dry_run? do
      Mix.Task.run("compile")
    else
      Mix.Task.run("app.config")
    end

    results =
      source_files()
      |> Task.async_stream(&process_file(&1, dry_run?), ordered: true, timeout: :infinity)
      |> Enum.map(&unwrap_result!/1)

    modified_results = Enum.filter(results, & &1.changed?)

    Enum.each(modified_results, fn result ->
      if dry_run? do
        Mix.shell().info("Would modify #{result.path}")
      else
        Mix.shell().info(result.path)
      end
    end)

    if data? and not dry_run? do
      schemas =
        modified_results
        |> Enum.flat_map(& &1.schemas)
        |> Enum.uniq()
        |> Enum.map(&schema_metadata!/1)

      backfill_data!(repos, args, schemas, chunk_size)
    end

    :ok
  end

  defp repos_from_options!(opts, args) do
    if Keyword.has_key?(opts, :repo) do
      reject_blank_repo_values!(opts)
      parse_repo(args)
    else
      [auto_detect_repo!()]
    end
  end

  defp reject_blank_repo_values!(opts) do
    if opts
       |> Keyword.get_values(:repo)
       |> Enum.any?(&blank_repo_value?/1) do
      Mix.raise("Cannot run --data without an Ecto repo; pass --repo MyApp.Repo")
    end
  end

  defp blank_repo_value?(repo) when is_binary(repo), do: String.trim(repo) == ""

  defp auto_detect_repo! do
    app = Mix.Project.config()[:app]

    if is_nil(app) do
      Mix.raise("Could not auto-detect application name; pass --repo MyApp.Repo")
    end

    Application.load(app)

    case Application.get_env(app, :ecto_repos) do
      [repo] ->
        repo

      repos when is_list(repos) and repos != [] ->
        Mix.raise(
          "Multiple Ecto repos found for application #{inspect(app)}; pass --repo MyApp.Repo"
        )

      _other ->
        Mix.raise("No Ecto repos found for application #{inspect(app)}; pass --repo MyApp.Repo")
    end
  end

  defp process_file(path, dry_run?) do
    source = File.read!(path)
    ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)
    walk_ast = prune_quoted(ast)
    replacements = ector_namespace_replacements(walk_ast, source)
    schemas = schema_modules(walk_ast)
    updated_source = apply_replacements(source, replacements)
    changed? = updated_source != source

    if changed? and not dry_run? do
      File.write!(path, updated_source)
    end

    {:ok, %{path: path, changed?: changed?, schemas: schemas}}
  rescue
    exception ->
      {:error, path, exception, __STACKTRACE__}
  end

  defp source_files do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&skip_source_file?/1)
    |> Enum.sort()
  end

  defp skip_source_file?(path) do
    Mix.Project.config()[:app] == :ector and
      (String.starts_with?(path, "lib/ector/") ||
         String.starts_with?(path, "lib/mix/tasks/ector."))
  end

  defp prune_quoted(ast) do
    Macro.prewalk(ast, fn
      {:quote, _meta, _args} -> {:__ector_migrate_quoted__, [], []}
      node -> node
    end)
  end

  defp unwrap_result!({:ok, {:ok, result}}), do: result

  defp unwrap_result!({:ok, {:error, path, exception, stacktrace}}) do
    reraise "failed to process #{path}: #{Exception.message(exception)}", stacktrace
  end

  defp ector_namespace_replacements(ast, source) do
    {_ast, replacements} =
      Macro.prewalk(ast, [], fn
        {:use, _meta, [{:__aliases__, alias_meta, [:Ecto, :Schema]} | _rest]} = node, acc ->
          {node, [{alias_meta, "Ecto.Schema", "Ector.Node"} | acc]}

        {:__aliases__, alias_meta, [:Ecto, :Repo]} = node, acc ->
          {node, [{alias_meta, "Ecto.Repo", "Ector.Repo"} | acc]}

        {:__aliases__, alias_meta, [:Ecto, :Query]} = node, acc ->
          {node, [{alias_meta, "Ecto.Query", "Ector.Query"} | acc]}

        node, acc ->
          {node, acc}
      end)

    replacements
    |> Enum.map(&replacement_for_alias(source, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp replacement_for_alias(source, {meta, source_alias, replacement_alias}) do
    with line when is_integer(line) <- Keyword.get(meta, :line),
         column when is_integer(column) <- Keyword.get(meta, :column),
         {:ok, offset} <- line_column_offset(source, line, column),
         {:ok, start} <- find_token(source, offset, source_alias) do
      {start, byte_size(source_alias), replacement_alias}
    else
      _other -> nil
    end
  end

  defp line_column_offset(source, line, column) do
    lines = String.split(source, "\n", trim: false)

    if line > 0 and line <= length(lines) and column > 0 do
      offset =
        lines
        |> Enum.take(line - 1)
        |> Enum.reduce(0, &(byte_size(&1) + 1 + &2))

      {:ok, offset + column - 1}
    else
      :error
    end
  end

  defp find_token(source, offset, token) do
    rest = binary_part(source, offset, byte_size(source) - offset)

    case :binary.match(rest, token) do
      {relative_start, _length} -> {:ok, offset + relative_start}
      :nomatch -> :error
    end
  end

  defp apply_replacements(source, replacements) do
    replacements
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(source, fn {start, length, replacement}, acc ->
      before = binary_part(acc, 0, start)
      after_replacement = binary_part(acc, start + length, byte_size(acc) - start - length)

      before <> replacement <> after_replacement
    end)
  end

  defp schema_modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [module_ast, [do: body]]} = node, acc ->
          module = module_from_ast(module_ast)

          if module && uses_ecto_schema?(body) do
            {node, [module | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp module_from_ast({:__aliases__, _meta, parts}) when is_list(parts) do
    Module.concat(parts)
  end

  defp module_from_ast(module) when is_atom(module), do: module
  defp module_from_ast(_ast), do: nil

  defp uses_ecto_schema?(body) do
    {_body, found?} =
      Macro.prewalk(body, false, fn
        {:use, _meta, [{:__aliases__, _alias_meta, [:Ecto, :Schema]} | _rest]} = node, _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp schema_metadata!(module) when is_atom(module) do
    Code.ensure_loaded?(module) ||
      Mix.raise("Could not load schema module #{inspect(module)} before data backfill")

    primary_key =
      case module.__schema__(:primary_key) do
        [field] ->
          field

        [] ->
          Mix.raise("Cannot backfill #{inspect(module)} because it has no primary key")

        fields ->
          Mix.raise(
            "Cannot backfill #{inspect(module)} with composite primary key #{inspect(fields)}"
          )
      end

    %{
      module: module,
      label: Ector.Node.label_for(module),
      source: module.__schema__(:source),
      fields: module.__schema__(:fields),
      field_types: schema_field_types(module),
      primary_key: primary_key,
      associations: schema_associations(module)
    }
  end

  defp schema_field_types(module) when is_atom(module) do
    module.__schema__(:fields)
    |> Map.new(&{&1, module.__schema__(:type, &1)})
  end

  defp schema_associations(module) when is_atom(module) do
    module.__schema__(:associations)
    |> Enum.map(fn name ->
      module
      |> apply(:__schema__, [:association, name])
      |> normalize_association()
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_association(%Ecto.Association.BelongsTo{} = association) do
    association_map = Map.from_struct(association)

    %{
      cardinality: :one,
      direction: :incoming,
      name: association.field,
      owner: association.owner,
      owner_key: association.owner_key,
      related_key: Map.get(association_map, :related_key, :id),
      target: association.related
    }
  end

  defp normalize_association(%Ecto.Association.Has{} = association) do
    association_map = Map.from_struct(association)

    %{
      cardinality: association.cardinality,
      direction: :outgoing,
      name: association.field,
      owner: association.owner,
      owner_key: association.owner_key,
      related_key: Map.get(association_map, :related_key),
      target: association.related
    }
  end

  defp normalize_association(_association), do: nil

  defp backfill_data!(_repos, _args, [], _chunk_size), do: :ok

  defp backfill_data!(repos, args, schemas, chunk_size) do
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    Enum.each(repos, fn repo ->
      repo = ensure_repo(repo, args)

      case Ecto.Migrator.with_repo(repo, &backfill_repo!(&1, schemas, chunk_size),
             mode: :temporary
           ) do
        {:ok, _result, _apps} ->
          :ok

        {:error, error} ->
          Mix.raise("Could not start repo #{inspect(repo)}, error: #{inspect(error)}")
      end
    end)
  end

  defp backfill_repo!(repo, schemas, chunk_size) do
    ensure_storage!(repo)

    id_dictionary =
      Map.new(schemas, fn schema ->
        {schema.module, backfill_nodes!(repo, schema, chunk_size)}
      end)

    Enum.each(edge_specs(schemas), &backfill_edges!(repo, &1, id_dictionary, chunk_size))
  end

  defp ensure_storage!(repo) do
    Ecto.Migrator.up(repo, @migration_version, Mix.Tasks.Ector.Migrate.StorageMigration,
      log: false
    )
  end

  defp backfill_nodes!(repo, schema, chunk_size) do
    stream_legacy_rows(repo, schema, chunk_size, fn rows ->
      {legacy_ids, node_rows} =
        Enum.map_reduce(rows, [], fn row, acc ->
          storage_id = Ecto.UUID.generate(version: 7, precision: :monotonic)
          legacy_id = Map.fetch!(row, schema.primary_key)

          node_row = %{
            id: storage_id,
            label: schema.label,
            properties: normalize_row_json(row, schema.field_types)
          }

          {{legacy_id, storage_id}, [node_row | acc]}
        end)

      insert_storage_rows!(repo, Ector.Node, node_rows)
      Map.new(legacy_ids)
    end)
    |> Enum.reduce(%{}, fn
      {:ok, chunk_map}, acc when is_map(chunk_map) ->
        Map.merge(acc, chunk_map)

      {:exit, reason}, _acc ->
        Mix.raise("failed to backfill #{inspect(schema.module)} rows: #{inspect(reason)}")
    end)
  end

  defp backfill_edges!(repo, spec, id_dictionary, chunk_size) do
    stream_legacy_rows(repo, spec.child, chunk_size, fn rows ->
      edge_rows =
        rows
        |> Enum.flat_map(&edge_row_for(&1, spec, id_dictionary))

      insert_storage_rows!(repo, Ector.Edge, edge_rows)
    end)
    |> Enum.each(fn
      {:ok, :ok} ->
        :ok

      {:exit, reason} ->
        Mix.raise(
          "failed to backfill #{inspect(spec.parent.module)} -> #{inspect(spec.child.module)} edges: #{inspect(reason)}"
        )
    end)
  end

  defp edge_row_for(row, spec, id_dictionary) do
    with parent_legacy_id when not is_nil(parent_legacy_id) <- Map.get(row, spec.foreign_key),
         child_legacy_id when not is_nil(child_legacy_id) <- Map.get(row, spec.child.primary_key),
         {:ok, source_id} <-
           lookup_storage_id(id_dictionary, spec.parent.module, parent_legacy_id),
         {:ok, target_id} <- lookup_storage_id(id_dictionary, spec.child.module, child_legacy_id) do
      [
        %{
          id: Ecto.UUID.generate(version: 7, precision: :monotonic),
          label: spec.label,
          source_id: source_id,
          target_id: target_id,
          properties: %{}
        }
      ]
    else
      _missing -> []
    end
  end

  defp lookup_storage_id(id_dictionary, module, legacy_id) do
    with {:ok, module_map} <- Map.fetch(id_dictionary, module),
         {:ok, storage_id} <- Map.fetch(module_map, legacy_id) do
      {:ok, storage_id}
    else
      :error -> :error
    end
  end

  defp stream_legacy_rows(repo, schema, chunk_size, callback) do
    query = from(row in schema.source, select: map(row, ^schema.fields))
    dynamic_repo = repo.get_dynamic_repo()
    task = legacy_row_task(repo, dynamic_repo, callback)
    task_options = legacy_row_task_options(repo)

    if concurrent_stream_checkout?(repo) do
      {:ok, results} =
        repo.transaction(
          fn ->
            query
            |> repo.stream()
            |> Stream.chunk_every(chunk_size)
            |> Task.async_stream(task, task_options)
            |> Enum.to_list()
          end,
          timeout: :infinity
        )

      results
    else
      stream_legacy_rows_synchronously!(repo, schema, query, chunk_size, callback)
    end
  end

  defp legacy_row_task(repo, dynamic_repo, callback) do
    fn rows ->
      with_independent_repo_worker(repo, dynamic_repo, fn ->
        callback.(rows)
      end)
    end
  end

  defp legacy_row_task_options(repo) do
    max_concurrency =
      repo
      |> repo_pool_size()
      |> min(System.schedulers_online())
      |> max(1)

    [max_concurrency: max_concurrency, ordered: false, timeout: :infinity]
  end

  defp concurrent_stream_checkout?(repo), do: repo_pool_size(repo) > 1

  defp repo_pool_size(repo) do
    repo.config()
    |> Keyword.get(:pool_size, System.schedulers_online())
  end

  defp stream_legacy_rows_synchronously!(repo, _schema, query, chunk_size, callback) do
    {:ok, results} =
      repo.transaction(
        fn ->
          query
          |> repo.stream()
          |> Stream.chunk_every(chunk_size)
          |> Enum.reduce([], fn rows, acc ->
            [{:ok, callback.(rows)} | acc]
          end)
          |> Enum.reverse()
        end,
        timeout: :infinity
      )

    results
  end

  defp with_independent_repo_worker(repo, dynamic_repo, callback) do
    previous_dynamic_repo = repo.put_dynamic_repo(dynamic_repo)
    Process.delete(:"$callers")

    try do
      callback.()
    after
      repo.put_dynamic_repo(previous_dynamic_repo)
    end
  end

  defp insert_storage_rows!(_repo, _schema, []), do: :ok

  defp insert_storage_rows!(repo, schema, rows) do
    rows = encode_storage_rows(repo, rows)
    target = storage_target(repo, schema)

    case repo.insert_all(target, rows, insert_all_opts(repo)) do
      {count, _result} when count == length(rows) ->
        :ok

      {count, _result} ->
        Mix.raise(
          "Expected to insert #{length(rows)} #{schema.__schema__(:source)} rows, inserted #{count}"
        )
    end
  end

  defp storage_target(repo, schema) do
    Map.get(%{Ecto.Adapters.SQLite3 => schema.__schema__(:source)}, repo.__adapter__(), schema)
  end

  defp insert_all_opts(repo) do
    Map.get(%{Ecto.Adapters.Postgres => [prepare: :unnamed]}, repo.__adapter__(), [])
  end

  defp encode_storage_rows(repo, rows) do
    row_encoder =
      Map.get(
        %{Ecto.Adapters.SQLite3 => &encode_sqlite_storage_rows/1},
        repo.__adapter__(),
        &Function.identity/1
      )

    row_encoder.(rows)
  end

  defp encode_sqlite_storage_rows(rows) do
    Enum.map(
      rows,
      &Map.update!(&1, :properties, fn value -> Ector.Translator.encode_json!(value) end)
    )
  end

  defp edge_specs(schemas) do
    schemas_by_module = Map.new(schemas, &{&1.module, &1})

    schemas
    |> Enum.flat_map(fn schema ->
      Enum.flat_map(
        schema.associations,
        &edge_specs_for_association(schema, &1, schemas_by_module)
      )
    end)
    |> Enum.uniq_by(&{&1.parent.module, &1.child.module, &1.foreign_key, &1.label})
  end

  defp edge_specs_for_association(
         schema,
         %{direction: :incoming} = association,
         schemas_by_module
       ) do
    case Map.fetch(schemas_by_module, association.target) do
      {:ok, parent} ->
        [
          %{
            parent: parent,
            child: schema,
            foreign_key: association.owner_key,
            label: edge_label_for(association, schemas_by_module)
          }
        ]

      :error ->
        []
    end
  end

  defp edge_specs_for_association(
         schema,
         %{direction: :outgoing} = association,
         schemas_by_module
       ) do
    case {Map.fetch(schemas_by_module, association.target), association.related_key} do
      {{:ok, child}, foreign_key} when is_atom(foreign_key) ->
        [
          %{
            parent: schema,
            child: child,
            foreign_key: foreign_key,
            label: edge_label_for(association, schemas_by_module)
          }
        ]

      _other ->
        []
    end
  end

  defp edge_label_for(%{direction: :incoming} = association, schemas_by_module) do
    case inverse_outgoing_association(association, schemas_by_module) do
      nil -> named_edge_label(association.name)
      inverse_association -> edge_label_for(inverse_association, schemas_by_module)
    end
  end

  defp edge_label_for(%{name: name}, _schemas_by_module), do: named_edge_label(name)

  defp inverse_outgoing_association(%{owner: owner, target: target}, schemas_by_module) do
    schemas_by_module
    |> Map.fetch!(target)
    |> Map.fetch!(:associations)
    |> Enum.filter(&(&1.direction == :outgoing and &1.target == owner))
    |> case do
      [association] -> association
      _ambiguous_or_missing -> nil
    end
  end

  defp named_edge_label(name) when is_atom(name) do
    name |> Atom.to_string() |> String.upcase()
  end

  defp normalize_row_json(row, field_types) when is_map(row) and is_map(field_types) do
    Map.new(row, fn {field, value} ->
      {to_string(field), normalize_field_json(value, Map.get(field_types, field))}
    end)
  end

  defp normalize_field_json(value, :decimal) when is_binary(value) or is_number(value) do
    case Decimal.parse(to_string(value)) do
      {decimal, ""} -> Decimal.to_string(decimal)
      _other -> normalize_json(value)
    end
  end

  defp normalize_field_json(value, :map) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} -> normalize_json(decoded)
      {:error, _reason} -> value
    end
  end

  defp normalize_field_json(value, type) when is_atom(type) do
    case Ecto.Type.load(type, value) do
      {:ok, loaded} -> normalize_json(loaded)
      :error -> normalize_json(value)
    end
  rescue
    UndefinedFunctionError -> normalize_json(value)
  end

  defp normalize_field_json(value, _type), do: normalize_json(value)

  defp normalize_json(%Decimal{} = value), do: Decimal.to_string(value)
  defp normalize_json(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_json(%{} = value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_json(nested_value)} end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value
end

defmodule Mix.Tasks.Ector.Migrate.StorageMigration do
  @moduledoc false

  use Ector.Migration

  def up do
    Ector.Migration.up()
  end

  def down do
    Ector.Migration.down()
  end
end
