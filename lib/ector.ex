defmodule Ector do
  @moduledoc ~S"""
  The top-level query façade for Ector.

  `Ector` is the consumer-facing entry point that mirrors `Ecto.Query`. Each
  macro here forwards to `Ector.Query`, which rewrites domain field access into
  the shared JSON storage shape before handing the expression to Ecto. This lets
  you keep writing near-vanilla Ecto while Ector routes everything through the
  `nodes`/`edges` topology.

  ## Stability

  The macros in this module are part of Ector's **public, SemVer-stable API**.

  ## Usage

  Import the façade to get the relational query DSL backed by Ector storage:

      import Ector

      from(p in Product)
      |> where([p], p.status == "active")
      |> select([p], p.name)

  For nested graph joins, see `Ector.join/3`. For persistence, see `Ector.Repo`.
  """

  @doc """
  Builds an Ector query from a domain schema or queryable.

  Delegates to `Ector.Query.from/2`.
  """
  defmacro from(expr, opts \\ []) do
    quote do
      require Ector.Query
      Ector.Query.from(unquote(expr), unquote(opts))
    end
  end

  @doc """
  Adds a `where` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.where/3`.
  """
  defmacro where(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.where(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds an `or_where` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.or_where/3`.
  """
  defmacro or_where(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.or_where(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds a `select` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.select/3`.
  """
  defmacro select(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.select(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds an `order_by` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.order_by/3`.
  """
  defmacro order_by(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.order_by(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds a `group_by` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.group_by/3`.
  """
  defmacro group_by(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.group_by(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds a `having` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.having/3`.
  """
  defmacro having(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.having(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds an `or_having` expression after rewriting domain field accesses.

  Delegates to `Ector.Query.or_having/3`.
  """
  defmacro or_having(query, binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.or_having(unquote(query), unquote(binding), unquote(expr))
    end
  end

  @doc """
  Builds a rewritten dynamic query expression.

  Delegates to `Ector.Query.dynamic/2`.
  """
  defmacro dynamic(binding \\ [], expr) do
    quote do
      require Ector.Query
      Ector.Query.dynamic(unquote(binding), unquote(expr))
    end
  end

  @doc """
  Adds a graph association join to a query.

  Delegates to `Ector.Query.join/3`.
  """
  defmacro join(query, association_name, opts \\ []) do
    quote do
      require Ector.Query
      Ector.Query.join(unquote(query), unquote(association_name), unquote(opts))
    end
  end
end
