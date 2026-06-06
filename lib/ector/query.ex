defmodule Ector.Query do
  @moduledoc ~S'''
  Ector-aware query macros built on top of `Ecto.Query`.

  `Ector.Query` keeps the caller-facing syntax of relational Ecto while routing
  domain fields through the shared JSON storage shape. The source module remains
  in the query source tuple for hydration, but the database source becomes the
  physical Ector table.

  ## Source translation

      iex> module = Module.concat(__MODULE__, SourceDocUser)
      iex> {:module, ^module, _, _} =
      ...>   Module.create(module, quote do
      ...>     use Ector.Node
      ...>     schema do
      ...>       field(:status, :string)
      ...>     end
      ...>   end, Macro.Env.location(__ENV__))
      iex> {query, _binding} = Code.eval_quoted(quote do
      ...>   require Ector.Query
      ...>   Ector.Query.from(user in unquote(module))
      ...> end)
      iex> elem(query.from.source, 0)
      "nodes"
      iex> elem(query.from.source, 1) == module
      true
      iex> hd(query.wheres).params
      [{"SourceDocUser", {0, :label}}]

  ## Field redirection

  A normal domain field access starts as ordinary Elixir AST:

      c.status

  Before Ecto sees the expression, Ector rewrites it to Ecto's native JSON path
  form:

      c.properties["status"]

  Ecto then lowers that bracket access into its internal `json_extract_path`
  query expression:

      iex> module = Module.concat(__MODULE__, FilterDocUser)
      iex> {:module, ^module, _, _} =
      ...>   Module.create(module, quote do
      ...>     use Ector.Node
      ...>     schema do
      ...>       field(:status, :string)
      ...>     end
      ...>   end, Macro.Env.location(__ENV__))
      iex> {query, _binding} = Code.eval_quoted(quote do
      ...>   require Ector.Query
      ...>   value = "active"
      ...>   Ector.Query.from(user in unquote(module))
      ...>   |> Ector.Query.where([user], user.status == ^value)
      ...> end)
      iex> {:==, _, [{:json_extract_path, _, [_, ["status"]]}, {:^, [], [0]}]} = List.last(query.wheres).expr
      iex> List.last(query.wheres).params
      [{"active", :any}]
  '''

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
        opts_with_label = [{:where, label_filter} | rewritten_opts]

        quote do
          require Ecto.Query
          unquote(label_var) = unquote(module.__ector_label__())
          Ecto.Query.from(unquote(rewritten_expr), unquote(opts_with_label))
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
  Adds a join to a query.

  Logical `assoc/2` joins are expanded into two physical joins: a hidden join to
  the shared `edges` table and a final join to the target `nodes` table. The
  caller's `as:` alias is assigned only to the final target binding.
  """
  defmacro join(query, qual, binding \\ [], expr, opts \\ [])

  defmacro join(query, qual, binding, expr, opts) when is_list(binding) and is_list(opts) do
    case parse_assoc_join(expr, opts) do
      {:ok, source_binding, target_binding, association_name, target_alias} ->
        build_assoc_join(
          query,
          qual,
          binding,
          source_binding,
          target_binding,
          association_name,
          target_alias
        )

      :error ->
        rewritten_opts = rewrite_join_opts(opts)

        quote do
          require Ecto.Query

          Ecto.Query.join(
            unquote(query),
            unquote(qual),
            unquote(binding),
            unquote(expr),
            unquote(rewritten_opts)
          )
        end
    end
  end

  defmacro join(_query, _qual, binding, _expr, opts) when is_list(opts) do
    raise ArgumentError,
          "invalid binding passed to Ector.Query.join/5, should be a list of variables, got: #{Macro.to_string(binding)}"
  end

  defmacro join(_query, _qual, _binding, _expr, opts) do
    raise ArgumentError,
          "invalid opts passed to Ector.Query.join/5, should be a list, got: #{Macro.to_string(opts)}"
  end

  @doc false
  @spec __association__!(Ecto.Queryable.t(), atom()) :: map()
  def __association__!(queryable, association_name) when is_atom(association_name) do
    query = Ecto.Queryable.to_query(queryable)
    module = source_module!(query.from.source)

    Enum.find(module.__ector_associations__(), &(&1.name == association_name)) ||
      raise ArgumentError,
            "unknown Ector association #{inspect(association_name)} for #{inspect(module)}"
  end

  @doc false
  @spec __edge_label__(map()) :: String.t()
  def __edge_label__(%{opts: %{through: through}}) do
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

  def __edge_label__(%{name: name}) when is_atom(name) do
    name |> Atom.to_string() |> String.upcase()
  end

  @doc false
  @spec __storage_source__(module()) :: {String.t(), module()}
  def __storage_source__(module) when is_atom(module) do
    {module.__ector_table__() |> Atom.to_string(), module}
  end

  defp build_assoc_join(
         query,
         qual,
         binding,
         source_binding,
         target_binding,
         association_name,
         target_alias
       ) do
    edge_binding = Macro.unique_var(:ector_edge, __MODULE__)
    edge_alias = String.to_atom("__edge_#{target_alias}_#{System.unique_integer([:positive])}")
    association_var = Macro.unique_var(:ector_association, __MODULE__)
    edge_label_var = Macro.unique_var(:ector_edge_label, __MODULE__)
    target_label_var = Macro.unique_var(:ector_target_label, __MODULE__)
    target_source_var = Macro.unique_var(:ector_target_source, __MODULE__)
    edge_source_var = Macro.unique_var(:ector_edge_source, __MODULE__)
    second_binding = binding ++ [edge_binding]

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

      unquote(association_var) =
        Ector.Query.__association__!(unquote(query), unquote(association_name))

      unquote(edge_label_var) = Ector.Query.__edge_label__(unquote(association_var))
      unquote(target_label_var) = unquote(association_var).target.__ector_label__()
      unquote(target_source_var) = Ector.Query.__storage_source__(unquote(association_var).target)
      unquote(edge_source_var) = {"edges", Ector.Edge}

      case unquote(association_var).direction do
        :outgoing ->
          unquote(query)
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
          unquote(query)
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

  defp rewrite_from_source({:in, meta, [binding, source]}, caller) do
    case Macro.expand(source, caller) do
      module when is_atom(module) ->
        if ector_schema_module?(module) do
          source_tuple = Macro.escape(__storage_source__(module))
          {:ok, {:in, meta, [binding, source_tuple]}, label_binding(binding), module}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp rewrite_from_source(source, caller) do
    case Macro.expand(source, caller) do
      module when is_atom(module) ->
        if ector_schema_module?(module) do
          binding = Macro.unique_var(:ector_source, __MODULE__)
          source_tuple = Macro.escape(__storage_source__(module))
          {:ok, {:in, [], [binding, source_tuple]}, binding, module}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp label_binding([binding | _rest]), do: binding
  defp label_binding(binding), do: binding

  defp label_filter_ast(binding, label_var) do
    {:==, [], [field_call_ast(binding, :label), {:^, [], [label_var]}]}
  end

  defp field_call_ast(binding, field) do
    {:field, [], [binding, field]}
  end

  defp parse_assoc_join(
         {:in, _meta,
          [target_binding, {:assoc, _assoc_meta, [source_binding, association_name]}]},
         opts
       )
       when is_atom(association_name) do
    {:ok, source_binding, target_binding, association_name, join_alias!(opts)}
  end

  defp parse_assoc_join(_expr, _opts), do: :error

  defp join_alias!(opts) do
    case Keyword.fetch(opts, :as) do
      {:ok, alias_name} when is_atom(alias_name) ->
        alias_name

      {:ok, other} ->
        raise ArgumentError,
              "Ector assoc joins require a compile time atom `as:` alias, got: #{Macro.to_string(other)}"

      :error ->
        raise ArgumentError,
              "Ector assoc joins require an `as:` alias for the target node binding"
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

  defp rewrite_join_opts(opts) do
    Enum.map(opts, fn
      {:on, expr} -> {:on, rewrite_ast(expr)}
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

  defp source_module!({_source, module}) when is_atom(module) do
    if ector_schema_module?(module), do: module, else: raise_non_ector_source!(module)
  end

  defp source_module!(source) do
    raise ArgumentError, "expected an Ector query source, got: #{inspect(source)}"
  end

  defp raise_non_ector_source!(module) do
    raise ArgumentError, "expected an Ector schema module, got: #{inspect(module)}"
  end

  defp ector_schema_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ector_kind__, 0) and
      function_exported?(module, :__ector_label__, 0) and
      function_exported?(module, :__ector_table__, 0)
  end
end
