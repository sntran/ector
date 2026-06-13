defmodule Ector.Query do
  @moduledoc ~S"""
  Ector-aware query macros built on top of `Ecto.Query`.

  `Ector.Query` keeps the caller-facing syntax of relational Ecto while routing
  domain fields through the shared JSON storage shape. The source tuple keeps
  the caller's domain module until the repo boundary so Ector can hydrate rows
  without a registry; `Ector.Repo` swaps that source to the physical `nodes` or
  `edges` schema immediately before handing the query to Ecto's planner.
  """

  @physical_fields [:__id__, :label, :source_id, :target_id]
  @rewritable_clauses [:where, :or_where, :select, :order_by, :group_by, :having, :or_having]

  @doc """
  Builds an Ector query from a domain schema or queryable.

  Ector schema modules are converted to `{table, module}` sources such as
  `{"nodes", MyApp.User}` and receive an automatic label filter. Other
  queryables are delegated to `Ecto.Query.from/2` after expression options are
  rewritten.
  """
  defmacro from(expr, opts \\ []) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "second argument to `from` must be a compile time keyword list"
    end

    rewritten_opts = rewrite_query_opts(opts)

    case rewrite_from_source(expr, __CALLER__) do
      {:ok, rewritten_expr, label_binding, module} ->
        label_var = Macro.unique_var(:ector_label, __MODULE__)
        label_filter = label_filter_ast(label_binding, label_var)
        opts_with_label = opts_with_label_filter(rewritten_opts, label_filter)

        quote do
          require Ecto.Query
          unquote(label_var) = unquote(module.__ector_label__())
          Ecto.Query.from(unquote(rewritten_expr), unquote(opts_with_label))
        end

      {:defer, deferred_expr, label_binding, module} ->
        source_var = Macro.unique_var(:ector_source, __MODULE__)
        label_var = Macro.unique_var(:ector_label, __MODULE__)
        label_filter = label_filter_ast(label_binding, label_var)
        opts_with_label = opts_with_label_filter(rewritten_opts, label_filter)
        rewritten_expr = put_deferred_source(deferred_expr, source_var)

        quote do
          require Ecto.Query

          if Ector.Query.__ector_schema_module__(unquote(module)) do
            unquote(source_var) =
              {unquote(module).__ector_table__() |> Atom.to_string(), unquote(module)}

            unquote(label_var) = unquote(module).__ector_label__()
            Ecto.Query.from(unquote(rewritten_expr), unquote(opts_with_label))
          else
            Ecto.Query.from(unquote(expr), unquote(rewritten_opts))
          end
        end

      :error ->
        quote do
          require Ecto.Query
          Ecto.Query.from(unquote(expr), unquote(rewritten_opts))
        end
    end
  end

  @doc """
  Builds a rewritten dynamic query expression.
  """
  defmacro dynamic(binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.dynamic(unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds a `where` expression after rewriting domain field accesses.
  """
  defmacro where(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.where(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds an `or_where` expression after rewriting domain field accesses.
  """
  defmacro or_where(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.or_where(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds a `select` expression after rewriting domain field accesses.
  """
  defmacro select(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.select(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds an `order_by` expression after rewriting domain field accesses.
  """
  defmacro order_by(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.order_by(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds a `group_by` expression after rewriting domain field accesses.
  """
  defmacro group_by(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.group_by(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds a `having` expression after rewriting domain field accesses.
  """
  defmacro having(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.having(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds an `or_having` expression after rewriting domain field accesses.
  """
  defmacro or_having(query, binding \\ [], expr) do
    rewritten_expr = rewrite_ast(expr)

    quote do
      require Ecto.Query
      Ecto.Query.or_having(unquote(query), unquote(binding), unquote(rewritten_expr))
    end
  end

  @doc """
  Adds a graph association join to a query.

  The association is expanded into two physical inner joins: a hidden join to
  the shared `edges` table and a final join to the target `nodes` table. The
  caller's `as:` alias is assigned only to the final target binding.
  """
  defmacro join(query, association_name, opts \\ []) do
    unless is_atom(association_name) do
      raise ArgumentError,
            "Ector.Query.join/3 expects a compile time atom association name, got: #{Macro.to_string(association_name)}"
    end

    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "Ector.Query.join/3 expects opts to be a compile time keyword list, got: #{Macro.to_string(opts)}"
    end

    target_alias = join_alias!(opts)
    source_alias = join_source_alias!(opts)
    source_binding = Macro.unique_var(:ector_source, __MODULE__)
    target_binding = Macro.unique_var(target_alias, __MODULE__)

    source_binding_list =
      if is_nil(source_alias), do: [source_binding], else: [{source_alias, source_binding}]

    build_assoc_join(
      query,
      :inner,
      source_binding_list,
      source_binding,
      target_binding,
      association_name,
      target_alias,
      source_alias
    )
  end

  @doc false
  @spec __join_source_module__(Ecto.Queryable.t(), atom() | nil) :: module()
  def __join_source_module__(queryable, source_alias) do
    query = Ecto.Queryable.to_query(queryable)

    case join_source(query, source_alias) do
      {:ok, {_source, module}} when is_atom(module) ->
        if ector_schema_module?(module) do
          module
        else
          raise ArgumentError, "expected an Ector schema module, got: #{inspect(module)}"
        end

      {:ok, source} ->
        raise ArgumentError, "expected an Ector query source, got: #{inspect(source)}"

      :error ->
        if is_nil(source_alias) do
          source = if query.from, do: query.from.source, else: nil

          raise ArgumentError,
                "expected an Ector query source, got: #{inspect(source)}"
        else
          raise ArgumentError,
                "unknown Ector join source alias #{inspect(source_alias)} in query"
        end
    end
  end

  defp build_assoc_join(
         query,
         qual,
         binding,
         source_binding,
         target_binding,
         association_name,
         target_alias,
         source_alias
       ) do
    edge_binding = Macro.unique_var(:ector_edge, __MODULE__)
    edge_alias = String.to_atom("__edge_#{target_alias}_#{System.unique_integer([:positive])}")
    association_var = Macro.unique_var(:ector_association, __MODULE__)
    query_var = Macro.unique_var(:ector_query, __MODULE__)
    source_module_var = Macro.unique_var(:ector_source_module, __MODULE__)
    edge_label_var = Macro.unique_var(:ector_edge_label, __MODULE__)
    target_label_var = Macro.unique_var(:ector_target_label, __MODULE__)
    target_source_var = Macro.unique_var(:ector_target_source, __MODULE__)
    edge_source_var = Macro.unique_var(:ector_edge_source, __MODULE__)

    second_binding =
      if is_nil(source_alias) do
        binding ++ [{:..., [], []}, edge_binding]
      else
        [{:..., [], []}, edge_binding]
      end

    outgoing_edge_on =
      edge_on_ast(edge_binding, source_binding, :source_id, :__id__, edge_label_var)

    incoming_edge_on =
      edge_on_ast(edge_binding, source_binding, :target_id, :__id__, edge_label_var)

    outgoing_target_on =
      target_on_ast(target_binding, edge_binding, :__id__, :target_id, target_label_var)

    incoming_target_on =
      target_on_ast(target_binding, edge_binding, :__id__, :source_id, target_label_var)

    quote do
      require Ecto.Query

      unquote(query_var) = unquote(query)

      unquote(source_module_var) =
        Ector.Query.__join_source_module__(unquote(query_var), unquote(source_alias))

      unquote(association_var) =
        Ector.Query.__association__!(
          unquote(source_module_var),
          unquote(association_name)
        )

      unquote(edge_label_var) =
        Ector.Query.__edge_label__(unquote(association_var))

      unquote(target_label_var) = unquote(association_var).target.__ector_label__()

      unquote(target_source_var) =
        {unquote(association_var).target.__ector_table__() |> Atom.to_string(),
         unquote(association_var).target}

      unquote(edge_source_var) = {"edges", Ector.Edge}

      case unquote(association_var).direction do
        :outgoing ->
          unquote(query_var)
          |> Ecto.Query.join(
            unquote(qual),
            unquote(binding),
            unquote(edge_binding) in ^unquote(edge_source_var),
            as: unquote(edge_alias),
            on: unquote(outgoing_edge_on)
          )
          |> Ecto.Query.join(
            unquote(qual),
            unquote(second_binding),
            unquote(target_binding) in ^unquote(target_source_var),
            as: unquote(target_alias),
            on: unquote(outgoing_target_on)
          )

        :incoming ->
          unquote(query_var)
          |> Ecto.Query.join(
            unquote(qual),
            unquote(binding),
            unquote(edge_binding) in ^unquote(edge_source_var),
            as: unquote(edge_alias),
            on: unquote(incoming_edge_on)
          )
          |> Ecto.Query.join(
            unquote(qual),
            unquote(second_binding),
            unquote(target_binding) in ^unquote(target_source_var),
            as: unquote(target_alias),
            on: unquote(incoming_target_on)
          )
      end
    end
  end

  @doc false
  @spec __association__!(module(), atom()) :: map()
  def __association__!(module, association_name)
      when is_atom(module) and is_atom(association_name) do
    Enum.find(module_associations(module), &(&1.name == association_name)) ||
      raise ArgumentError,
            "unknown Ector association #{inspect(association_name)} for #{inspect(module)}"
  end

  @doc false
  @spec __edge_label__(map()) :: String.t()
  def __edge_label__(association) when is_map(association), do: edge_label_for(association)

  @doc false
  @spec __ector_schema_module__(module()) :: boolean()
  def __ector_schema_module__(module) when is_atom(module), do: ector_schema_module?(module)

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

  defp named_edge_label(name) when is_atom(name) do
    name |> Atom.to_string() |> String.upcase()
  end

  defp edge_schema_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ector_kind__, 0) and
      function_exported?(module, :__ector_label__, 0) and module.__ector_kind__() == :edge
  end

  defp edge_schema_module?(_module), do: false

  defp rewrite_from_source({:in, meta, [binding, source]}, caller) do
    case Macro.expand(source, caller) do
      module when is_atom(module) ->
        cond do
          ector_schema_module?(module) ->
            source_tuple = Macro.escape(storage_source_tuple(module))
            {:ok, {:in, meta, [binding, source_tuple]}, label_binding(binding), module}

          Code.ensure_loaded?(module) ->
            :error

          true ->
            {:defer, {:in, meta, [binding, nil]}, label_binding(binding), module}
        end

      _other ->
        :error
    end
  end

  defp rewrite_from_source(source, caller) do
    case Macro.expand(source, caller) do
      module when is_atom(module) ->
        cond do
          ector_schema_module?(module) ->
            binding = Macro.unique_var(:ector_source, __MODULE__)
            source_tuple = Macro.escape(storage_source_tuple(module))
            {:ok, {:in, [], [binding, source_tuple]}, binding, module}

          Code.ensure_loaded?(module) ->
            :error

          true ->
            binding = Macro.unique_var(:ector_source, __MODULE__)
            {:defer, {:in, [], [binding, nil]}, binding, module}
        end

      _other ->
        :error
    end
  end

  defp label_binding([binding | _rest]), do: binding
  defp label_binding(binding), do: binding

  defp put_deferred_source({:in, meta, [binding, nil]}, source_var) do
    {:in, meta, [binding, source_var]}
  end

  defp label_filter_ast(binding, label_var) do
    {:==, [], [field_call_ast(binding, :label), {:^, [], [label_var]}]}
  end

  defp opts_with_label_filter([{:as, _alias_name} = as_option | rest], label_filter) do
    [as_option, {:where, label_filter} | rest]
  end

  defp opts_with_label_filter(opts, label_filter), do: [{:where, label_filter} | opts]

  defp field_call_ast(binding, field) do
    {:field, [], [binding, field]}
  end

  defp join_alias!(opts) do
    case Keyword.fetch(opts, :as) do
      {:ok, alias_name} when is_atom(alias_name) ->
        alias_name

      {:ok, other} ->
        raise ArgumentError,
              "Ector graph joins require a compile time atom `as:` alias, got: #{Macro.to_string(other)}"

      :error ->
        raise ArgumentError,
              "Ector graph joins require an `as:` alias for the target node binding"
    end
  end

  defp join_source_alias!(opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, alias_name} when is_atom(alias_name) ->
        alias_name

      {:ok, other} ->
        raise ArgumentError,
              "Ector graph joins require `from:` to be a compile time atom alias, got: #{Macro.to_string(other)}"

      :error ->
        nil
    end
  end

  defp join_source(%Ecto.Query{from: nil}, nil), do: :error
  defp join_source(%Ecto.Query{from: %{source: source}}, nil), do: {:ok, source}

  defp join_source(%Ecto.Query{} = query, source_alias) when is_atom(source_alias) do
    aliases = query.aliases || %{}

    with {:ok, index} <- Map.fetch(aliases, source_alias),
         {:ok, source} <- source_at_binding(query, index) do
      {:ok, source}
    else
      _other -> :error
    end
  end

  defp source_at_binding(%Ecto.Query{from: %{source: source}}, 0), do: {:ok, source}

  defp source_at_binding(%Ecto.Query{joins: joins}, index) when is_integer(index) and index > 0 do
    case Enum.at(joins, index - 1) do
      %Ecto.Query.JoinExpr{source: source} -> {:ok, source}
      _other -> :error
    end
  end

  defp edge_on_ast(
         edge_binding,
         source_binding,
         edge_link_field,
         source_link_field,
         edge_label_var
       ) do
    {:and, [],
     [
       {:==, [],
        [dot_ast(edge_binding, edge_link_field), dot_ast(source_binding, source_link_field)]},
       {:==, [], [dot_ast(edge_binding, :label), {:^, [], [edge_label_var]}]}
     ]}
  end

  defp target_on_ast(
         target_binding,
         edge_binding,
         target_link_field,
         edge_link_field,
         target_label_var
       ) do
    {:and, [],
     [
       {:==, [],
        [dot_ast(target_binding, target_link_field), dot_ast(edge_binding, edge_link_field)]},
       {:==, [], [dot_ast(target_binding, :label), {:^, [], [target_label_var]}]}
     ]}
  end

  defp dot_ast(binding, field) do
    {{:., [], [binding, field]}, [], []}
  end

  defp rewrite_query_opts(opts) do
    Enum.map(opts, fn
      {clause, expr} when clause in @rewritable_clauses -> {clause, rewrite_ast(expr)}
      other -> other
    end)
  end

  defp rewrite_ast(ast) do
    ast
    |> shield_pins()
    |> Macro.prewalk(&rewrite_field_access/1)
    |> unshield_generated_physical_fields()
    |> unshield_pins()
  end

  defp shield_pins(ast) do
    Macro.prewalk(ast, fn
      {:^, _meta, _args} = pinned -> %{__ector_query_pinned_ast__: pinned}
      other -> other
    end)
  end

  defp unshield_pins(ast) do
    Macro.prewalk(ast, fn
      %{__ector_query_pinned_ast__: pinned} -> pinned
      other -> other
    end)
  end

  defp unshield_generated_physical_fields(ast) do
    Macro.prewalk(ast, fn
      %{__ector_query_physical_field_ast__: physical_field} -> physical_field
      other -> other
    end)
  end

  # This is the core redirection point: `c.status` arrives as a remote-call AST
  # whose receiver is a query binding variable. Storage fields stay physical;
  # domain fields become JSON path reads from the shared `properties` payload.
  defp rewrite_field_access(
         {{:., dot_meta, [{binding, binding_meta, context}, field]}, meta, []} = ast
       )
       when is_atom(binding) and is_atom(context) and is_atom(field) do
    if field in @physical_fields do
      ast
    else
      properties_access =
        {{:., dot_meta, [{binding, binding_meta, context}, :properties]}, meta, []}

      {{:., [from_brackets: true], [Access, :get]}, [from_brackets: true],
       [%{__ector_query_physical_field_ast__: properties_access}, Atom.to_string(field)]}
    end
  end

  defp rewrite_field_access(other), do: other

  defp storage_source_tuple(module) when is_atom(module) do
    {module.__ector_table__() |> Atom.to_string(), module}
  end

  defp ector_schema_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ector_kind__, 0) and
      function_exported?(module, :__ector_label__, 0) and
      function_exported?(module, :__ector_table__, 0)
  end
end
