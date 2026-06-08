import Config

postgres? = System.get_env("STORE_ADAPTER") in ["postgres", "postgresql"]

common = [
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 2,
  log: false
]

if postgres? do
  database_url =
    System.get_env("STORE_DATABASE_URL") ||
      System.get_env("DATABASE_URL") ||
      raise "set STORE_DATABASE_URL or DATABASE_URL when STORE_ADAPTER=postgres"

  config :store,
         Store.RelationalRepo,
         Keyword.merge(common,
           url: System.get_env("STORE_RELATIONAL_DATABASE_URL") || database_url,
           migration_source: "store_relational_schema_migrations",
           priv: "priv/relational_repo"
         )

  config :store,
         Store.EctorRepo,
         Keyword.merge(common,
           url: System.get_env("STORE_ECTOR_DATABASE_URL") || database_url,
           migration_source: "store_ector_schema_migrations",
           priv: "priv/ector_repo"
         )
else
  tmp = Path.expand("../tmp", __DIR__)

  config :store,
         Store.RelationalRepo,
         Keyword.merge(common,
           database: Path.join(tmp, "store_relational_dev.sqlite3"),
           migration_source: "store_relational_schema_migrations",
           priv: "priv/relational_repo",
           journal_mode: :wal,
           busy_timeout: 5_000
         )

  config :store,
         Store.EctorRepo,
         Keyword.merge(common,
           database: Path.join(tmp, "store_ector_dev.sqlite3"),
           migration_source: "store_ector_schema_migrations",
           priv: "priv/ector_repo",
           journal_mode: :wal,
           busy_timeout: 5_000
         )
end
