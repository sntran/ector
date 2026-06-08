defmodule Store.Sandbox do
  @moduledoc """
  Disposable database lifecycle helpers for the example tests and benchmarks.

  The helper intentionally drops only the tables owned by this standalone
  example. It supports the configured adapter, so the same tests can run on the
  default SQLite files or a PostgreSQL database selected with `STORE_ADAPTER`.
  """

  @relational_tables ~w(store_cart_items store_carts store_customers store_products)
  @ector_tables ~w(edges nodes)

  @doc "Starts the application repositories, drops owned tables, and runs migrations."
  @spec reset!() :: :ok
  def reset! do
    start_repos!()
    drop!(Store.RelationalRepo, @relational_tables)
    drop!(Store.EctorRepo, @ector_tables)
    migrate!()
  end

  @doc "Runs all pending migrations for both repositories."
  @spec migrate!() :: :ok
  def migrate! do
    migrate_repo!(Store.RelationalRepo)
    migrate_repo!(Store.EctorRepo)
    :ok
  end

  @doc "Drops all tables owned by the example repositories."
  @spec drop!() :: :ok
  def drop! do
    drop!(Store.RelationalRepo, @relational_tables)
    drop!(Store.EctorRepo, @ector_tables)
    :ok
  end

  defp start_repos! do
    case Application.ensure_all_started(:store) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
    end
  end

  defp migrate_repo!(repo) do
    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(repo, fn started_repo ->
        with_ignored_migration_module_conflicts(fn ->
          Ecto.Migrator.run(started_repo, migrations_path(repo), :up, all: true, log: false)
        end)
      end)

    :ok
  end

  defp with_ignored_migration_module_conflicts(fun) when is_function(fun, 0) do
    previous = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(ignore_module_conflict: previous)
    end
  end

  defp migrations_path(repo) do
    repo
    |> repo_priv!()
    |> Path.join("migrations")
    |> then(&Application.app_dir(:store, &1))
  end

  defp repo_priv!(repo) do
    repo.config()
    |> Keyword.fetch!(:priv)
  end

  defp drop!(repo, tables) do
    Enum.each(tables ++ [migration_source(repo)], fn table ->
      repo.query!("DROP TABLE IF EXISTS #{table}#{drop_suffix(repo)}")
    end)
  end

  defp migration_source(repo),
    do: Keyword.get(repo.config(), :migration_source, "schema_migrations")

  defp drop_suffix(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> " CASCADE"
      _adapter -> ""
    end
  end
end
