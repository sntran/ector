defmodule Ector.TestRepo.SQLite do
  @moduledoc false

  use Ector.Repo, otp_app: :ector, adapter: Ecto.Adapters.SQLite3
end

defmodule Ector.TestRepo.Postgres do
  @moduledoc false

  use Ector.Repo, otp_app: :ector, adapter: Ecto.Adapters.Postgres
end

defmodule Ector.TestRepo do
  @moduledoc false

  @migration_source "ector_schema_migrations"
  @sqlite_path Path.join(System.tmp_dir!(), "ector_test.sqlite3")

  def adapter do
    if postgres?(), do: Ecto.Adapters.Postgres, else: Ecto.Adapters.SQLite3
  end

  def repo_module do
    if postgres?(), do: Ector.TestRepo.Postgres, else: Ector.TestRepo.SQLite
  end

  def postgres?, do: is_binary(database_url()) and database_url() != ""
  def sqlite?, do: not postgres?()
  def database_url, do: System.get_env("DATABASE_URL")
  def migration_source, do: @migration_source

  def setup! do
    if sqlite?() do
      File.rm(@sqlite_path)
    end

    _ = Application.fetch_env!(:ector, repo_module())

    case repo_module().start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  def migrate!(version, migration, opts \\ []) do
    _ = Ecto.Migrator.up(repo_module(), version, migration, Keyword.merge([log: false], opts))
    :ok
  end

  def rollback!(version, migration, opts \\ []) do
    _ = Ecto.Migrator.down(repo_module(), version, migration, Keyword.merge([log: false], opts))
    :ok
  end

  def drop_core_tables! do
    Enum.each(
      [
        "DROP TABLE IF EXISTS edges",
        "DROP TABLE IF EXISTS nodes",
        "DROP TABLE IF EXISTS #{@migration_source}"
      ],
      &query!/1
    )
  end

  def query!(statement, params \\ []) do
    repo_module().query!(statement, params)
  end

  def table_exists?(table) when is_binary(table) do
    if postgres?() do
      query_single_value!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1)",
        [table]
      )
    else
      query_single_value!(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table]
      ) in [1, true]
    end
  end

  def column_names(table) when is_binary(table) do
    if postgres?() do
      query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position",
        [table]
      ).rows
      |> List.flatten()
    else
      query!("PRAGMA table_info(#{table})").rows
      |> Enum.map(fn [_cid, name | _rest] -> name end)
    end
  end

  def column_type(table, column) when is_binary(table) and is_binary(column) do
    if postgres?() do
      query_single_value!(
        "SELECT data_type FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
        [table, column]
      )
    else
      query!("PRAGMA table_info(#{table})").rows
      |> Enum.find_value(fn [_cid, name, type | _rest] -> if name == column, do: type end)
    end
  end

  def index_names(table) when is_binary(table) do
    if postgres?() do
      query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = $1 ORDER BY indexname",
        [table]
      ).rows
      |> List.flatten()
    else
      query!(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? ORDER BY name",
        [table]
      ).rows
      |> List.flatten()
    end
  end

  def index_sql(index_name) when is_binary(index_name) do
    if postgres?() do
      query_single_value!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1",
        [index_name]
      )
    else
      query_single_value!(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
        [index_name]
      )
    end
  end

  defp query_single_value!(statement, params) do
    statement
    |> query!(params)
    |> Map.fetch!(:rows)
    |> List.first()
    |> List.first()
  end
end
