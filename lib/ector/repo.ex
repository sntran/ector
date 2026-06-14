defmodule Ector.Repo do
  @moduledoc """
  Drop-in `Ecto.Repo` wrapper for Ector-backed schemas.

  `use Ector.Repo` keeps the standard repository process and adapter behavior,
  while intercepting the operations that need to preserve Ector's domain-facing
  illusion over the shared `nodes` and `edges` tables.

  The wrapper hydrates raw storage rows back into the caller's schema modules,
  persists nested graph inserts through a transaction boundary, rewrites bulk
  `set` updates into adapter-native JSON mutations, preloads graph associations,
  and ensures deletes target the hidden `__id__` routing key instead of the
  caller's business identifier.

  Ector queries intentionally carry the domain module in their source tuple
  until this boundary. Just before execution, the wrapper swaps those sources to
  `Ector.Node` or `Ector.Edge`, rewrites hidden `__id__` field reads to the
  physical `id` column, and hydrates only full-row results. Explicit `select`
  projections are returned unchanged.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi

  @property_update_operators [:set, :inc, :push]
  @storage_update_fields [:__id__, :label, :source_id, :target_id, :properties]

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
                     update_all: 3,
                     preload: 2,
                     preload: 3

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

      def preload(struct_or_structs, preloads, opts \\ []) do
        if Ector.Repo.preloadable?(struct_or_structs) do
          Ector.Repo.preload(__MODULE__, struct_or_structs, preloads, opts)
        else
          super(struct_or_structs, preloads, opts)
        end
      end
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

  @doc """
  Executes an Ector-aware bulk update through the provided repo.

  Standard Ecto update operators targeting domain fields are translated into
  adapter-specific mutations of the shared `properties` JSON column. The
  rewritten query is then delegated to the repo's native `update_all/3`.
  """
  @spec update_all(module() | term(), term() | module(), Keyword.t(), Keyword.t()) :: term()
  def update_all(first, second, updates, opts \\ [])

  def update_all(first, second, updates, opts)
      when is_list(updates) and is_list(opts) do
    case resolve_update_all_args(first, second) do
      {:ok, repo, queryable} ->
        case rewrite_update_all(repo, queryable, updates) do
          {:ok, query, rewritten_updates} -> repo.update_all(query, rewritten_updates, opts)
          :error -> repo.update_all(queryable, updates, opts)
        end

      :error ->
        raise ArgumentError,
              "expected an Ecto repo module plus an Ector queryable, got: #{inspect(first)} and #{inspect(second)}"
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

  @doc """
  Preloads Ector graph associations through the provided repo.

  The accepted preload shape mirrors Ecto's atom/list/keyword syntax. Ector
  batches every top-level association over the parent list, reads the shared
  `edges` and `nodes` tables directly, hydrates target nodes into their domain
  structs, and then recurses into nested preloads.
  """
  @spec preload(module(), nil | struct() | [struct() | nil], term(), Keyword.t()) ::
          nil | struct() | [struct() | nil]
  def preload(repo, struct_or_structs, preloads, opts \\ [])

  def preload(repo, nil, _preloads, opts) when is_atom(repo) and is_list(opts), do: nil

  def preload(repo, structs, preloads, opts)
      when is_atom(repo) and is_list(structs) and is_list(opts) do
    cond do
      ector_preloadable_list?(structs) ->
        preload_structs(repo, structs, normalize_preloads(preloads), opts)

      ecto_preloadable_list?(structs) ->
        repo.preload(structs, preloads, opts)

      true ->
        raise ArgumentError,
              "expected all preload entries to be Ector schema structs, standard Ecto schema structs, or nil, got: #{inspect(structs)}"
    end
  end

  def preload(repo, %module{} = struct, preloads, opts)
      when is_atom(repo) and is_atom(module) and is_list(opts) do
    if ector_schema_module?(module) do
      case preload(repo, [struct], preloads, opts) do
        [loaded] -> loaded
      end
    else
      repo.preload(struct, preloads, opts)
    end
  end

  def preload(_repo, struct_or_structs, _preloads, _opts) do
    raise ArgumentError,
          "expected an Ector schema struct, nil, or a list of Ector schema structs, got: #{inspect(struct_or_structs)}"
  end

  @doc false
  @spec preloadable?(term()) :: boolean()
  def preloadable?(nil), do: true
  def preloadable?([]), do: true

  def preloadable?(%module{}) when is_atom(module) do
    ector_schema_module?(module)
  end

  def preloadable?(structs) when is_list(structs) do
    Enum.all?(structs, fn
      nil -> true
      %module{} -> ector_schema_module?(module)
      _other -> false
    end)
  end

  def preloadable?(_other), do: false

  defp ector_preloadable_list?(structs) when is_list(structs) do
    Enum.all?(structs, fn
      nil -> true
      %module{} -> ector_schema_module?(module)
      _other -> false
    end)
  end

  defp ecto_preloadable_list?(structs) when is_list(structs) do
    Enum.any?(structs, &struct?/1) and
      Enum.all?(structs, fn
        nil -> true
        %module{} -> ecto_schema_module?(module) and not ector_schema_module?(module)
        _other -> false
      end)
  end

  defp struct?(%module{}) when is_atom(module), do: true
  defp struct?(_other), do: false

  @spec normalize_preloads(term()) :: [{atom(), term()}]
  defp normalize_preloads([]), do: []

  defp normalize_preloads(association_name) when is_atom(association_name),
    do: [{association_name, []}]

  defp normalize_preloads(preloads) when is_list(preloads) do
    Enum.flat_map(preloads, fn
      association_name when is_atom(association_name) ->
        [{association_name, []}]

      {association_name, nested_preloads} when is_atom(association_name) ->
        [{association_name, nested_preloads}]

      preload ->
        raise ArgumentError, "unsupported Ector preload expression: #{inspect(preload)}"
    end)
  end

  defp normalize_preloads(preloads) do
    raise ArgumentError, "unsupported Ector preload expression: #{inspect(preloads)}"
  end

  @spec preload_structs(module(), [struct() | nil], [{atom(), term()}], Keyword.t()) :: [
          struct() | nil
        ]
  defp preload_structs(_repo, structs, [], _opts), do: structs
  defp preload_structs(_repo, [], _preloads, _opts), do: []

  defp preload_structs(repo, structs, preloads, opts) do
    structs
    |> Enum.with_index()
    |> Enum.group_by(&preload_group_key/1)
    |> Enum.flat_map(fn
      {nil, indexed_nil_values} ->
        indexed_nil_values

      {module, indexed_structs} ->
        structs_for_module = Enum.map(indexed_structs, &elem(&1, 0))

        loaded_structs =
          Enum.reduce(preloads, structs_for_module, fn {association_name, nested_preloads}, acc ->
            preload_association(repo, module, acc, association_name, nested_preloads, opts)
          end)

        loaded_structs
        |> Enum.zip(Enum.map(indexed_structs, &elem(&1, 1)))
        |> Enum.map(fn {struct, index} -> {struct, index} end)
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp preload_group_key({nil, _index}), do: nil
  defp preload_group_key({%module{}, _index}) when is_atom(module), do: module

  @spec preload_association(module(), module(), [struct()], atom(), term(), Keyword.t()) :: [
          struct()
        ]
  defp preload_association(repo, module, parents, association_name, nested_preloads, opts)
       when is_atom(repo) and is_atom(module) and is_atom(association_name) do
    association = association!(module, association_name)

    unless ector_schema_module?(association.target) do
      raise ArgumentError,
            "expected Ector association #{inspect(module)}.#{association_name} to target an Ector schema, got: #{inspect(association.target)}"
    end

    case association.direction do
      :outgoing ->
        preload_edge_association(
          repo,
          parents,
          association,
          :source_id,
          :target_id,
          nested_preloads,
          opts
        )

      :incoming ->
        preload_incoming_association(repo, parents, association, nested_preloads, opts)
    end
  end

  defp preload_edge_association(
         repo,
         parents,
         association,
         parent_edge_key,
         target_edge_key,
         nested_preloads,
         opts
       ) do
    parent_ids = parents |> hidden_ids() |> Enum.uniq()

    loaded_pairs =
      if parent_ids == [] do
        []
      else
        repo
        |> fetch_outgoing_foreign_key_targets(association, parent_ids, opts)
        |> Kernel.++(
          fetch_edge_targets(
            repo,
            association,
            parent_ids,
            parent_edge_key,
            target_edge_key,
            opts
          )
        )
        |> Enum.uniq_by(fn {parent_id, target} -> {parent_id, parent_hidden_id(target)} end)
      end
      |> preload_pair_targets(repo, nested_preloads, opts)

    stitch_loaded_association(parents, association, loaded_pairs)
  end

  defp preload_incoming_association(repo, parents, association, nested_preloads, opts) do
    {foreign_key_pairs, parents_without_foreign_key} = foreign_key_pairs(parents, association)

    foreign_key_loaded_pairs =
      repo
      |> fetch_foreign_key_targets(association, foreign_key_pairs, opts)

    foreign_key_parent_ids =
      foreign_key_pairs
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    loaded_parent_ids =
      foreign_key_loaded_pairs
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    unloaded_foreign_key_parents =
      Enum.filter(parents, fn parent ->
        parent_id = parent_hidden_id(parent)
        parent_id in foreign_key_parent_ids and parent_id not in loaded_parent_ids
      end)

    fallback_parents = parents_without_foreign_key ++ unloaded_foreign_key_parents

    fallback_parent_ids = fallback_parents |> hidden_ids() |> Enum.uniq()

    edge_loaded_pairs =
      if fallback_parent_ids == [] do
        []
      else
        fetch_edge_targets(repo, association, fallback_parent_ids, :target_id, :source_id, opts)
      end

    (foreign_key_loaded_pairs ++ edge_loaded_pairs)
    |> preload_pair_targets(repo, nested_preloads, opts)
    |> then(&stitch_loaded_association(parents, association, &1))
  end

  defp fetch_edge_targets(repo, association, parent_ids, parent_edge_key, target_edge_key, opts) do
    edge_label = edge_label_for(association)
    target_label = association.target.__ector_label__()

    query =
      from(edge in Ector.Edge,
        join: node in Ector.Node,
        on:
          field(node, :id) == field(edge, ^target_edge_key) and
            field(node, :label) == ^target_label,
        where:
          field(edge, :label) == ^edge_label and
            field(edge, ^parent_edge_key) in ^parent_ids,
        order_by: [asc: field(edge, ^parent_edge_key), asc: node.id],
        select: {field(edge, ^parent_edge_key), node}
      )

    repo.all(query, storage_opts(opts))
    |> Enum.map(fn {parent_id, row} -> {parent_id, hydrate(association.target, row)} end)
  end

  defp fetch_foreign_key_targets(_repo, _association, [], _opts), do: []

  defp fetch_foreign_key_targets(repo, association, foreign_key_pairs, opts) do
    target_ids =
      foreign_key_pairs
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    target_by_id =
      from(node in Ector.Node,
        where: node.label == ^association.target.__ector_label__() and node.id in ^target_ids,
        select: node
      )
      |> repo.all(storage_opts(opts))
      |> Enum.map(&hydrate(association.target, &1))
      |> Map.new(&{&1.__id__, &1})

    Enum.flat_map(foreign_key_pairs, fn {parent_id, target_id} ->
      case Map.fetch(target_by_id, target_id) do
        {:ok, target} -> [{parent_id, target}]
        :error -> []
      end
    end)
  end

  defp fetch_outgoing_foreign_key_targets(repo, association, parent_ids, opts) do
    case inverse_incoming_association(association) do
      nil ->
        []

      %{opts: association_opts} = inverse_association ->
        if Map.has_key?(association_opts, :through) do
          []
        else
          fetch_outgoing_foreign_key_targets(
            repo,
            association,
            inverse_association,
            parent_ids,
            opts
          )
        end
    end
  end

  defp fetch_outgoing_foreign_key_targets(
         repo,
         association,
         inverse_association,
         parent_ids,
         opts
       ) do
    foreign_key = association_foreign_key(inverse_association)

    from(node in Ector.Node,
      where:
        node.label == ^association.target.__ector_label__() and
          node.properties[^Atom.to_string(foreign_key)] in ^parent_ids,
      select: node
    )
    |> repo.all(storage_opts(opts))
    |> Enum.map(&hydrate(association.target, &1))
    |> Enum.map(fn target -> {Map.fetch!(target, foreign_key), target} end)
  end

  defp preload_pair_targets([], _repo, _nested_preloads, _opts), do: []

  defp preload_pair_targets(loaded_pairs, repo, nested_preloads, opts) do
    case normalize_preloads(nested_preloads) do
      [] ->
        loaded_pairs

      _normalized ->
        parent_ids = Enum.map(loaded_pairs, &elem(&1, 0))
        targets = Enum.map(loaded_pairs, &elem(&1, 1))

        repo
        |> preload(targets, nested_preloads, opts)
        |> then(&Enum.zip(parent_ids, &1))
    end
  end

  defp stitch_loaded_association(parents, association, loaded_pairs) do
    grouped_targets =
      loaded_pairs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(parents, fn parent ->
      parent_id = parent_hidden_id(parent)
      targets = Map.get(grouped_targets, parent_id, [])

      Map.put(parent, association.name, association_value(association, targets))
    end)
  end

  defp association_value(%{cardinality: :many}, targets), do: targets
  defp association_value(%{cardinality: :one}, [target | _targets]), do: target
  defp association_value(%{cardinality: :one}, []), do: nil

  defp foreign_key_pairs(parents, association) do
    foreign_key = association_foreign_key(association)

    Enum.reduce(parents, {[], []}, fn parent, {pairs, missing_parents} ->
      parent_id = parent_hidden_id(parent)
      target_id = Map.get(parent, foreign_key)

      cond do
        is_binary(parent_id) and parent_id != "" and valid_hidden_id?(target_id) ->
          {[{parent_id, target_id} | pairs], missing_parents}

        true ->
          {pairs, [parent | missing_parents]}
      end
    end)
    |> then(fn {pairs, missing_parents} ->
      {Enum.reverse(pairs), Enum.reverse(missing_parents)}
    end)
  end

  defp association_foreign_key(%{owner_key: owner_key}) when is_atom(owner_key), do: owner_key

  defp hidden_ids(structs) do
    structs
    |> Enum.map(&parent_hidden_id/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp valid_hidden_id?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_hidden_id?(_value), do: false

  defp parent_hidden_id(%{__id__: hidden_id}), do: hidden_id

  defp association!(module, association_name) do
    Enum.find(module_associations(module), &(&1.name == association_name)) ||
      raise ArgumentError,
            "unknown Ector association #{inspect(association_name)} for #{inspect(module)}"
  end

  defp module_associations(module) when is_atom(module) do
    module
    |> schema_associations()
    |> Kernel.++(ector_associations(module))
    |> merge_duplicate_associations()
  end

  defp schema_associations(module) when is_atom(module) do
    if function_exported?(module, :__schema__, 1) do
      module
      |> apply(:__schema__, [:associations])
      |> Enum.map(&schema_association(module, &1))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp schema_association(module, association_name) do
    if function_exported?(module, :__schema__, 1) do
      module
      |> apply(:__schema__, [:association, association_name])
      |> normalize_schema_association()
    else
      nil
    end
  end

  defp normalize_schema_association(%Ecto.Association.BelongsTo{} = association) do
    %{
      cardinality: :one,
      direction: :incoming,
      name: association.field,
      opts: schema_association_opts(association),
      owner: association.owner,
      owner_key: association.owner_key,
      target: association.related
    }
  end

  defp normalize_schema_association(%Ecto.Association.Has{} = association) do
    %{
      cardinality: association.cardinality,
      direction: :outgoing,
      name: association.field,
      opts: schema_association_opts(association),
      owner: association.owner,
      owner_key: association.owner_key,
      target: association.related
    }
  end

  defp normalize_schema_association(_association), do: nil

  defp schema_association_opts(association) do
    association
    |> Map.from_struct()
    |> Map.take([:through, :foreign_key])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp ector_associations(module) when is_atom(module) do
    if function_exported?(module, :__ector_associations__, 0) do
      module.__ector_associations__()
    else
      []
    end
  end

  defp merge_duplicate_associations(associations) do
    associations
    |> Enum.group_by(&association_identity/1)
    |> Enum.map(fn {_identity, duplicate_associations} ->
      Enum.reduce(duplicate_associations, %{}, fn association, acc ->
        Map.merge(acc, association, fn
          :opts, left, right -> Map.merge(left, right)
          _key, _left, right -> right
        end)
      end)
    end)
  end

  defp association_identity(%{
         cardinality: cardinality,
         direction: direction,
         name: name,
         owner: owner,
         target: target
       }) do
    {cardinality, direction, name, owner, target}
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

          properties_update =
            Ector.Translator.properties_update_expression(repo, set: set_updates)

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
  defp domain_set_updates(%Changeset{data: %{__struct__: module}, changes: changes})
       when is_atom(module) do
    property_fields = module |> property_fields() |> MapSet.new()

    changes
    |> Map.delete(:__ector_edges__)
    |> Enum.filter(fn {field_name, _value} -> MapSet.member?(property_fields, field_name) end)
    |> Enum.map(fn {field_name, value} -> {field_name, normalize_json(value)} end)
  end

  @spec rewrite_update_all(module(), term(), Keyword.t()) ::
          {:ok, Ecto.Query.t(), Keyword.t()} | :error
  defp rewrite_update_all(repo, queryable, updates) when is_atom(repo) and is_list(updates) do
    with {:ok, _module, query} <- storage_filter_query(queryable),
         {:ok, property_updates} <- extract_property_updates(updates) do
      properties_update = Ector.Translator.properties_update_expression(repo, property_updates)
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
    edge_label_from_through(through)
  end

  defp edge_label_for(%{direction: :incoming} = association) do
    case inverse_outgoing_association(association) do
      nil -> named_edge_label(association.name)
      inverse_association -> edge_label_for(inverse_association)
    end
  end

  defp edge_label_for(%{name: name}) when is_atom(name), do: named_edge_label(name)

  defp edge_label_from_through(through) do
    cond do
      edge_schema_module?(through) ->
        through.__ector_label__()

      is_atom(through) ->
        through |> Atom.to_string() |> String.upcase()

      is_binary(through) ->
        through |> Macro.underscore() |> String.upcase()

      true ->
        raise ArgumentError, "unsupported Ector edge label source: #{inspect(through)}"
    end
  end

  defp inverse_outgoing_association(%{owner: owner, target: target})
       when is_atom(owner) and is_atom(target) do
    target
    |> module_associations()
    |> Enum.filter(&(&1.direction == :outgoing and &1.target == owner))
    |> case do
      [association] -> association
      _ambiguous_or_missing -> nil
    end
  end

  defp inverse_incoming_association(%{owner: owner, target: target})
       when is_atom(owner) and is_atom(target) do
    target
    |> module_associations()
    |> Enum.filter(&(&1.direction == :incoming and &1.target == owner))
    |> case do
      [association] -> association
      _ambiguous_or_missing -> nil
    end
  end

  defp named_edge_label(name) when is_atom(name) do
    name |> Atom.to_string() |> String.upcase()
  end

  defp edge_schema_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ector_kind__, 0) and
      function_exported?(module, :__ector_label__, 0) and module.__ector_kind__() == :edge
  end

  defp edge_schema_module?(_module), do: false

  defp properties_from_changeset(%Changeset{} = changeset) do
    module = changeset.data.__struct__

    changeset
    |> Changeset.apply_changes()
    |> Map.take(property_fields(module))
    |> normalize_json()
  end

  defp property_fields(module) when is_atom(module) do
    module.__schema__(:fields) -- [:__id__]
  end

  defp extract_property_updates(updates) when is_list(updates) do
    Enum.reduce_while(updates, {:ok, []}, fn
      {operator, field_updates}, {:ok, acc}
      when operator in @property_update_operators and is_list(field_updates) ->
        if valid_property_updates?(operator, field_updates) do
          {:cont, {:ok, [{operator, field_updates} | acc]}}
        else
          {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, property_updates} -> {:ok, Enum.reverse(property_updates)}
      :error -> :error
    end
  end

  defp valid_property_updates?(operator, field_updates) when is_list(field_updates) do
    Enum.all?(field_updates, &valid_property_update?(operator, &1))
  end

  defp valid_property_update?(:inc, {field_name, value}) do
    valid_property_field?(field_name) and is_number(value)
  end

  defp valid_property_update?(operator, {field_name, _value}) when operator in [:set, :push] do
    valid_property_field?(field_name)
  end

  defp valid_property_update?(_operator, _update), do: false

  defp valid_property_field?(field_name) when is_atom(field_name) do
    field_name not in @storage_update_fields
  end

  defp valid_property_field?(field_name) when is_binary(field_name), do: field_name != ""
  defp valid_property_field?(_field_name), do: false

  defp resolve_update_all_args(first, second) do
    cond do
      repo_module?(first) -> {:ok, first, second}
      repo_module?(second) -> {:ok, second, first}
      true -> :error
    end
  end

  defp repo_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__adapter__, 0)
  end

  defp repo_module?(_other), do: false

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
    rewritten = %{query_expr | expr: rewrite_hidden_id_ast(expr)}

    if Map.has_key?(rewritten, :params) do
      %{rewritten | params: rewrite_hidden_id_params(rewritten.params)}
    else
      rewritten
    end
  end

  defp rewrite_hidden_id_ast(ast) do
    Macro.prewalk(ast, fn
      {{:., dot_meta, [binding, :__id__]}, call_meta, []} ->
        {{:., dot_meta, [binding, :id]}, call_meta, []}

      other ->
        other
    end)
  end

  defp rewrite_hidden_id_params(params) when is_list(params) do
    Enum.map(params, fn
      {value, {binding, :__id__}} when is_integer(binding) -> {value, {binding, :id}}
      param -> param
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

  defp ector_schema_module?(module) do
    is_atom(module) and Ector.Schema.ector_schema?(module) and
      function_exported?(module, :__ector_label__, 0) and
      function_exported?(module, :__ector_table__, 0)
  end

  defp ecto_schema_module?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
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
