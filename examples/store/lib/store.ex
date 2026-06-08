defmodule Store do
  @moduledoc """
  Standalone e-commerce showcase for comparing relational Ecto schemas with
  Ector's graph-backed dynamic schema engine.

  The project runs on SQLite by default. Set `STORE_ADAPTER=postgres` before
  compilation to exercise the same modules against PostgreSQL.
  """

  @adapter Application.compile_env(:store, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc "Returns the Ecto adapter compiled into the example repositories."
  @spec repo_adapter() :: module()
  def repo_adapter, do: @adapter

  @doc "Returns a short adapter label for logs, tests, and benchmark output."
  @spec adapter_name() :: :postgres | :sqlite
  def adapter_name do
    case @adapter do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
    end
  end
end
