defmodule Ector.Repo do
  @moduledoc """
  Drop-in `Ecto.Repo` wrapper for Ector-backed schemas.

  `use Ector.Repo` keeps the standard repository process and adapter behavior,
  while intercepting the operations that need to preserve Ector's domain-facing
  illusion over the shared `nodes` and `edges` tables.

  The wrapper hydrates raw storage rows back into the caller's schema modules,
  persists nested graph inserts through a transaction boundary, rewrites bulk
  `set` updates into adapter-native JSON mutations, and ensures deletes target
  the hidden `__id__` routing key instead of the caller's business identifier.

  Ector queries intentionally carry the domain module in their source tuple
  until this boundary. Just before execution, the wrapper swaps those sources to
  `Ector.Node` or `Ector.Edge`, rewrites hidden `__id__` field reads to the
  physical `id` column, and hydrates only full-row results. Explicit `select`
  projections are returned unchanged.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi

  @typedoc "Normalized JSON value stored in `nodes.properties` or `edges.properties`."
  @type json_value ::
          String.t() | number() | boolean() | nil | [json_value()] | %{String.t() => json_value()}

  @typedoc false
  @type storage_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:label) => String.t(),
          required(:properties) => %{String.t() => json_value()}
        }

  @typedoc false
  @type storage_result(schema) :: {:ok, {schema, Ecto.UUID.t()}} | {:error, Changeset.t()}

  @doc """
  Wraps `Ecto.Repo` with Ector-aware query hydration and persistence hooks.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Ecto.Repo, opts

      defoverridable all: 1,
                     all: 2,
                     one: 1,
                     one: 2,
                     insert: 1,
                     insert: 2,
                     update: 1,
                     update: 2,
                     delete: 1,
                     delete: 2,
                     delete_all: 1,
                     delete_all: 2,
                     update_all: 2,
                     update_all: 3

      def all(queryable, opts \\ []),
        do: Ector.Repo.all(__MODULE__, queryable, opts, fn q, o -> super(q, o) end)

      def one(queryable, opts \\ []),
        do: Ector.Repo.one(__MODULE__, queryable, opts, fn q, o -> super(q, o) end)

      def insert(struct_or_changeset, opts \\ []),
        do: Ector.Repo.insert(__MODULE__, struct_or_changeset, opts, fn s, o -> super(s, o) end)

      def update(struct_or_changeset, opts \\ []),
        do: Ector.Repo.update(__MODULE__, struct_or_changeset, opts, fn s, o -> super(s, o) end)

      def delete(struct_or_changeset, opts \\ []),
        do: Ector.Repo.delete(__MODULE__, struct_or_changeset, opts, fn s, o -> super(s, o) end)

      def delete_all(queryable, opts \\ []),
        do: Ector.Repo.delete_all(__MODULE__, queryable, opts, fn q, o -> super(q, o) end)

      def update_all(queryable, updates, opts \\ []),
        do:
          Ector.Repo.update_all(__MODULE__, queryable, updates, opts, fn q, u, o ->
            super(q, u, o)
          end)
    end
  end

  @doc false
  @spec all(module(), term(), Keyword.t(), (term(), Keyword.t() -> list())) :: list()
  def all(_repo, queryable, opts, fallback) when is_list(opts) and is_function(fallback, 2) do
    case storage_select_query(queryable) do
      {:ok, module, query, :hydrate} ->
        fallback.(query, opts)
        |> Enum.map(&hydrate_storage_row(module, &1))

      {:ok, _module, query, :projection} ->
        fallback.(query, opts)

      :error ->
        fallback.(queryable, opts)
    end
  end

  @doc false
  @spec one(module(), term(), Keyword.t(), (term(), Keyword.t() -> term())) :: term()
  def one(_repo, queryable, opts, fallback) when is_list(opts) and is_function(fallback, 2) do
    case storage_select_query(queryable) do
      {:ok, module, query, :hydrate} ->
        case fallback.(query, opts) do
          nil -> nil
          row -> hydrate_storage_row(module, row)
        end

      {:ok, _module, query, :projection} ->
        fallback.(query, opts)

      :error ->
        fallback.(queryable, opts)
    end
  end

  @doc false
  @spec insert(module(), term(), Keyword.t(), (term(), Keyword.t() -> term())) :: term()
  def insert(repo, struct_or_changeset, opts, fallback)
      when is_atom(repo) and is_list(opts) and is_function(fallback, 2) do
    case normalize_insertable(struct_or_changeset) do
      {:ok, changeset} -> insert_graph(repo, changeset, opts)
      :error -> fallback.(struct_or_changeset, opts)
    end
  end

  @doc false
  @spec update(module(), term(), Keyword.t(), (term(), Keyword.t() -> term())) :: term()
  def update(repo, struct_or_changeset, opts, fallback)
      when is_atom(repo) and is_list(opts) and is_function(fallback, 2) do
    case normalize_updateable(struct_or_changeset) do
      {:ok, changeset, module, hidden_id} ->
        update_hidden_id(repo, changeset, module, hidden_id, opts)

      {:error, changeset} ->
        {:error, changeset}

      :error ->
        fallback.(struct_or_changeset, opts)
    end
  end

  @doc false
  @spec delete(module(), term(), Keyword.t(), (term(), Keyword.t() -> term())) :: term()
  def delete(repo, struct_or_changeset, opts, fallback)
      when is_atom(repo) and is_list(opts) and is_function(fallback, 2) do
    case normalize_deleteable(struct_or_changeset) do
      {:ok, struct, module, hidden_id} -> delete_hidden_id(repo, struct, module, hidden_id, opts)
      {:error, changeset} -> {:error, changeset}
      :error -> fallback.(struct_or_changeset, opts)
    end
  end

  @doc false
  @spec delete_all(module(), term(), Keyword.t(), (term(), Keyword.t() -> term())) :: term()
  def delete_all(_repo, queryable, opts, fallback)
      when is_list(opts) and is_function(fallback, 2) do
    case storage_filter_query(queryable) do
      {:ok, _module, query} -> fallback.(query, opts)
      :error -> fallback.(queryable, opts)
    end
  end

  @doc false
  @spec update_all(module(), term(), Keyword.t(), Keyword.t(), (term(),
                                                                Keyword.t(),
                                                                Keyword.t() ->
                                                                  term())) :: term()
  def update_all(repo, queryable, updates, opts, fallback)
      when is_atom(repo) and is_list(updates) and is_list(opts) and is_function(fallback, 3) do
    case rewrite_update_all(repo, queryable, updates) do
      {:ok, query, rewritten_updates} -> fallback.(query, rewritten_updates, opts)
      :error -> fallback.(queryable, updates, opts)
    end
  end

  @spec storage_select_query(term()) ::
          {:ok, module(), Ecto.Query.t(), :hydrate | :projection} | :error
  defp storage_select_query(%Ecto.Query{} = query) do
    with {:ok, module} <- ector_query_domain_module(query) do
      hydration = if is_nil(query.select), do: :hydrate, else: :projection
      {:ok, module, executable_ector_query(query), hydration}
    end
  end

  defp storage_select_query(queryable) do
    with {:ok, module} <- ector_queryable_module(queryable) do
      {:ok, module,
       from(row in storage_schema(module),
         where: field(row, :label) == ^module.__ector_label__()
       ), :hydrate}
    end
  end

  @spec storage_filter_query(term()) :: {:ok, module(), Ecto.Query.t()} | :error
  defp storage_filter_query(%Ecto.Query{} = query) do
    with {:ok, module} <- ector_query_domain_module(query) do
      {:ok, module, executable_ector_query(query)}
    end
  end

  defp storage_filter_query(queryable) do
    with {:ok, module} <- ector_queryable_module(queryable) do
      {:ok, module,
       from(row in storage_schema(module), where: field(row, :label) == ^module.__ector_label__())}
    end
  end

  @spec normalize_insertable(term()) :: {:ok, Changeset.t()} | :error
  defp normalize_insertable(%Changeset{data: %{__struct__: module}} = changeset)
       when is_atom(module) do
    if ector_schema_module?(module), do: {:ok, changeset}, else: :error
  end

  defp normalize_insertable(_other), do: :error

  @spec normalize_deleteable(term()) ::
          {:ok, struct(), module(), Ecto.UUID.t()} | {:error, Changeset.t()} | :error
  defp normalize_deleteable(%Changeset{data: %{__struct__: module}} = changeset)
       when is_atom(module) do
    if ector_schema_module?(module) do
      changeset
      |> Changeset.apply_changes()
      |> normalize_deleteable()
    else
      :error
    end
  end

  defp normalize_deleteable(%module{} = struct) when is_atom(module) do
    if ector_schema_module?(module) do
      case Map.get(struct, :__id__) do
        hidden_id when is_binary(hidden_id) and hidden_id != "" ->
          {:ok, struct, module, hidden_id}

        _ ->
          {:error, Changeset.add_error(Changeset.change(struct), :__id__, "can't be blank")}
      end
    else
      :error
    end
  end

  defp normalize_deleteable(_other), do: :error

  @spec normalize_updateable(term()) ::
          {:ok, Changeset.t(), module(), Ecto.UUID.t()} | {:error, Changeset.t()} | :error
  defp normalize_updateable(%Changeset{data: %{__struct__: module}} = changeset)
       when is_atom(module) do
    cond do
      not ector_schema_module?(module) ->
        :error

      module.__ector_kind__() != :node ->
        {:error, Changeset.add_error(changeset, :base, "only node changesets can be updated")}

      true ->
        case Map.get(changeset.data, :__id__) do
          hidden_id when is_binary(hidden_id) and hidden_id != "" ->
            {:ok, changeset, module, hidden_id}

          _ ->
            {:error, Changeset.add_error(changeset, :__id__, "can't be blank")}
        end
    end
  end

  defp normalize_updateable(_other), do: :error

  @spec hydrate_storage_row(module(), term()) :: term()
  defp hydrate_storage_row(module, %Ector.Node{} = row), do: hydrate(module, row)
  defp hydrate_storage_row(module, %Ector.Edge{} = row), do: hydrate(module, row)
  defp hydrate_storage_row(_module, row), do: row

  @spec hydrate(module(), storage_row()) :: struct()
  defp hydrate(module, %{id: hidden_id, properties: properties})
       when is_atom(module) and is_map(properties) do
    property_fields = module.__schema__(:fields) -- [:__id__]

    property_values =
      Enum.reduce(property_fields, %{}, fn field_name, acc ->
        key = Atom.to_string(field_name)

        case fetch_property(properties, field_name, key) do
          {:ok, value} -> Map.put(acc, field_name, value)
          :error -> acc
        end
      end)

    struct(module, Map.put(property_values, :__id__, hidden_id))
  end

  @spec insert_graph(module(), Changeset.t(), Keyword.t()) ::
          {:ok, struct()} | {:error, Changeset.t()}
  defp insert_graph(repo, %Changeset{} = changeset, opts) when is_atom(repo) and is_list(opts) do
    cond do
      not changeset.valid? ->
        {:error, changeset}

      nested_edge_payload?(changeset) ->
        multi =
          Multi.new()
          |> Multi.run(:source, fn tx_repo, _changes ->
            case persist_changeset(tx_repo, changeset, storage_opts(opts)) do
              {:ok, {struct, _hidden_id}} -> {:ok, struct}
              {:error, invalid_changeset} -> {:error, invalid_changeset}
            end
          end)

        case repo.transact(multi) do
          {:ok, %{source: struct}} -> {:ok, struct}
          {:error, :source, invalid_changeset, _changes} -> {:error, invalid_changeset}
        end

      true ->
        case persist_changeset(repo, changeset, storage_opts(opts)) do
          {:ok, {struct, _hidden_id}} -> {:ok, struct}
          {:error, invalid_changeset} -> {:error, invalid_changeset}
        end
    end
  end

  @spec delete_hidden_id(module(), struct(), module(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, struct()} | {:error, Changeset.t()}
  defp delete_hidden_id(repo, struct, module, hidden_id, opts)
       when is_atom(repo) and is_atom(module) and is_binary(hidden_id) and is_list(opts) do
    query =
      from(row in storage_schema(module),
        where: field(row, :label) == ^module.__ector_label__() and field(row, :id) == ^hidden_id
      )

    case repo.delete_all(query, storage_opts(opts)) do
      {1, _} -> {:ok, struct}
      {0, _} -> {:error, Changeset.add_error(Changeset.change(struct), :__id__, "does not exist")}
    end
  end

  @spec update_hidden_id(module(), Changeset.t(), module(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, struct()} | {:error, Changeset.t()}
  defp update_hidden_id(repo, %Changeset{} = changeset, module, hidden_id, opts)
       when is_atom(repo) and is_atom(module) and is_binary(hidden_id) and is_list(opts) do
    cond do
      not changeset.valid? ->
        {:error, changeset}

      true ->
        set_updates = domain_set_updates(changeset)

        if set_updates == [] do
          {:ok, Changeset.apply_changes(changeset)}
        else
          query =
            from(row in storage_schema(module),
              where:
                field(row, :label) == ^module.__ector_label__() and
                  field(row, :id) == ^hidden_id
            )

          properties_update = Ector.Translator.properties_update_expression(repo, set_updates)

          case repo.update_all(query, [set: [properties: properties_update]], storage_opts(opts)) do
            {1, _} ->
              {:ok, Changeset.apply_changes(changeset)}

            {0, _} ->
              {:error, Changeset.add_error(changeset, :__id__, "does not exist")}
          end
        end
    end
  end

  @spec domain_set_updates(Changeset.t()) :: keyword()
  defp domain_set_updates(%Changeset{changes: changes}) do
    changes
    |> Map.drop([:__id__, :__ector_edges__])
    |> Enum.map(fn {field_name, value} -> {field_name, normalize_json(value)} end)
  end

  @spec rewrite_update_all(module(), term(), Keyword.t()) ::
          {:ok, Ecto.Query.t(), Keyword.t()} | :error
  defp rewrite_update_all(repo, queryable, updates) when is_atom(repo) and is_list(updates) do
    with {:ok, _module, query} <- storage_filter_query(queryable),
         {:ok, set_updates} <- extract_set_updates(updates) do
      properties_update = Ector.Translator.properties_update_expression(repo, set_updates)
      {:ok, query, [set: [properties: properties_update]]}
    else
      _ -> :error
    end
  end

  defp persist_changeset(repo, %Changeset{data: %{__struct__: module}} = changeset, opts)
       when is_atom(repo) and is_atom(module) and is_list(opts) do
    cond do
      not ector_schema_module?(module) ->
        {:error, Changeset.add_error(changeset, :base, "expected an Ector schema changeset")}

      module.__ector_kind__() != :node ->
        {:error,
         Changeset.add_error(
           changeset,
           :base,
           "edge changesets must be inserted through put_edge/3"
         )}

      not changeset.valid? ->
        {:error, changeset}

      true ->
        hidden_id = Ecto.UUID.autogenerate(version: 7, precision: :monotonic)
        properties = properties_from_changeset(changeset)
        row = %{id: hidden_id, label: module.__ector_label__(), properties: properties}

        case insert_storage_rows(repo, storage_schema(module), [row], opts) do
          {1, _} ->
            struct = hydrate(module, row)

            case persist_edges(repo, struct, changeset, hidden_id, opts) do
              :ok -> {:ok, {struct, hidden_id}}
              {:error, invalid_changeset} -> {:error, invalid_changeset}
            end

          _ ->
            {:error,
             Changeset.add_error(changeset, :base, "expected a single storage row to be inserted")}
        end
    end
  end

  defp persist_edges(repo, %{__struct__: module}, %Changeset{} = changeset, source_id, opts)
       when is_atom(repo) and is_atom(module) and is_binary(source_id) and is_list(opts) do
    module
    |> association_payloads(changeset)
    |> Enum.reduce_while(:ok, fn {association, payloads}, :ok ->
      Enum.reduce_while(payloads, :ok, fn {target_changeset, edge_properties}, :ok ->
        case persist_changeset(repo, target_changeset, opts) do
          {:ok, {_target_struct, target_id}} ->
            edge_row = %{
              id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
              label: edge_label_for(association),
              source_id: source_id,
              target_id: target_id,
              properties: normalize_json(edge_properties)
            }

            case insert_storage_rows(repo, Ector.Edge, [edge_row], opts) do
              {1, _} ->
                {:cont, :ok}

              _ ->
                {:halt,
                 {:error,
                  Changeset.add_error(changeset, association.name, "failed to persist edge")}}
            end

          {:error, invalid_changeset} ->
            {:halt, {:error, invalid_changeset}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, invalid_changeset} -> {:halt, {:error, invalid_changeset}}
      end
    end)
  end

  defp nested_edge_payload?(%Changeset{} = changeset) do
    changeset
    |> Map.get(:changes)
    |> Map.get(:__ector_edges__, %{})
    |> map_size()
    |> Kernel.>(0)
  end

  defp association_payloads(module, %Changeset{} = changeset) do
    edges = Map.get(changeset.changes, :__ector_edges__, %{})

    Enum.map(edges, fn {association_name, payloads} ->
      association =
        Enum.find(module.__ector_associations__(), &(&1.name == association_name)) ||
          raise ArgumentError,
                "unknown Ector association #{inspect(association_name)} for #{inspect(module)}"

      {association, payloads}
    end)
  end

  defp edge_label_for(%{opts: %{through: through}}) do
    cond do
      is_atom(through) and Code.ensure_loaded?(through) and
          function_exported?(through, :__ector_label__, 0) ->
        through.__ector_label__()

      is_atom(through) ->
        through |> Atom.to_string() |> String.upcase()

      is_binary(through) ->
        through |> Macro.underscore() |> String.upcase()

      true ->
        raise ArgumentError, "unsupported Ector edge label source: #{inspect(through)}"
    end
  end

  defp edge_label_for(%{name: name}) when is_atom(name) do
    name |> Atom.to_string() |> String.upcase()
  end

  defp properties_from_changeset(%Changeset{} = changeset) do
    changeset
    |> Changeset.apply_changes()
    |> Map.from_struct()
    |> Map.drop([:__id__])
    |> normalize_json()
  end

  defp extract_set_updates(set: set_updates) when is_list(set_updates), do: {:ok, set_updates}
  defp extract_set_updates(_updates), do: :error

  defp storage_opts(opts), do: Keyword.take(opts, [:prefix, :timeout, :log])

  defp insert_storage_rows(repo, schema, rows, opts)
       when is_atom(repo) and is_atom(schema) and is_list(rows) and is_list(opts) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 ->
        repo.insert_all(schema.__schema__(:source), Enum.map(rows, &encode_storage_row/1), opts)

      Ecto.Adapters.Postgres ->
        repo.insert_all(schema, rows, Keyword.put(opts, :prepare, :unnamed))

      _ ->
        repo.insert_all(schema, rows, opts)
    end
  end

  defp encode_storage_row(row) when is_map(row) do
    Map.update!(row, :properties, &Ector.Translator.encode_json!/1)
  end

  defp storage_schema(module) when is_atom(module) do
    case module.__ector_table__() do
      :nodes -> Ector.Node
      :edges -> Ector.Edge
    end
  end

  defp executable_ector_query(%Ecto.Query{} = query) do
    query
    |> rewrite_ector_query_sources()
    |> rewrite_hidden_id_fields()
  end

  defp rewrite_ector_query_sources(%Ecto.Query{} = query) do
    %{
      query
      | sources: nil,
        from: rewrite_from_source(query.from),
        joins: Enum.map(query.joins, &rewrite_join_source/1)
    }
  end

  defp rewrite_from_source(%Ecto.Query.FromExpr{} = from) do
    %{from | source: rewrite_storage_source(from.source)}
  end

  defp rewrite_join_source(%Ecto.Query.JoinExpr{} = join) do
    %{join | source: rewrite_storage_source(join.source)}
  end

  defp rewrite_storage_source({source, module}) when is_atom(module) do
    if ector_schema_module?(module) do
      {source || storage_source(module), storage_schema(module)}
    else
      {source, module}
    end
  end

  defp rewrite_storage_source(source), do: source

  defp storage_source(module) when is_atom(module) do
    module.__ector_table__() |> Atom.to_string()
  end

  defp rewrite_hidden_id_fields(%Ecto.Query{} = query) do
    %{
      query
      | wheres: Enum.map(query.wheres, &rewrite_query_expr_hidden_id/1),
        select: rewrite_query_expr_hidden_id(query.select),
        order_bys: Enum.map(query.order_bys, &rewrite_query_expr_hidden_id/1),
        group_bys: Enum.map(query.group_bys, &rewrite_query_expr_hidden_id/1),
        havings: Enum.map(query.havings, &rewrite_query_expr_hidden_id/1),
        distinct: rewrite_query_expr_hidden_id(query.distinct),
        limit: rewrite_query_expr_hidden_id(query.limit),
        offset: rewrite_query_expr_hidden_id(query.offset),
        joins: Enum.map(query.joins, &rewrite_join_expr_hidden_id/1)
    }
  end

  defp rewrite_join_expr_hidden_id(%Ecto.Query.JoinExpr{} = join) do
    %{join | on: rewrite_query_expr_hidden_id(join.on)}
  end

  defp rewrite_query_expr_hidden_id(nil), do: nil

  defp rewrite_query_expr_hidden_id(%{expr: expr} = query_expr) do
    %{query_expr | expr: rewrite_hidden_id_ast(expr)}
  end

  defp rewrite_hidden_id_ast(ast) do
    Macro.prewalk(ast, fn
      {{:., dot_meta, [binding, :__id__]}, call_meta, []} ->
        {{:., dot_meta, [binding, :id]}, call_meta, []}

      other ->
        other
    end)
  end

  defp ector_query_domain_module(%Ecto.Query{from: %{source: {_source, module}}})
       when is_atom(module) do
    if ector_schema_module?(module), do: {:ok, module}, else: :error
  end

  defp ector_query_domain_module(_query), do: :error

  defp ector_queryable_module(module) when is_atom(module) do
    if ector_schema_module?(module), do: {:ok, module}, else: :error
  end

  defp ector_queryable_module(_other), do: :error

  defp ector_schema_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ector_kind__, 0) and
      function_exported?(module, :__ector_label__, 0) and
      function_exported?(module, :__ector_table__, 0)
  end

  defp fetch_property(properties, atom_key, string_key) do
    cond do
      Map.has_key?(properties, atom_key) -> {:ok, Map.fetch!(properties, atom_key)}
      Map.has_key?(properties, string_key) -> {:ok, Map.fetch!(properties, string_key)}
      true -> :error
    end
  end

  defp normalize_json(%{} = value) do
    Enum.into(value, %{}, fn {key, nested_value} ->
      {to_string(key), normalize_json(nested_value)}
    end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value
end
