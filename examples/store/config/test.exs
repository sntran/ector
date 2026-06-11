import Config

config :logger, level: :warning
config :store, :catalog_page_size, 3

postgres? = System.get_env("STORE_ADAPTER") in ["postgres", "postgresql"]

common = [
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  log: false,
  pool_size: 1
]

config :store, StoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "store_test_secret_key_base_64_bytes_minimum_for_signed_live_sessions_123456789",
  server: false

if postgres? do
  database_url =
    System.get_env("STORE_DATABASE_URL") ||
      System.get_env("DATABASE_URL") ||
      raise "set STORE_DATABASE_URL or DATABASE_URL when STORE_ADAPTER=postgres"

  config :store,
         Store.Repo,
         Keyword.merge(common,
           url: database_url,
           migration_source: "store_schema_migrations",
           priv: "priv/repo"
         )
else
  tmp = Path.expand("../tmp", __DIR__)

  config :store,
         Store.Repo,
         Keyword.merge(common,
           database: Path.join(tmp, "store_test.sqlite3"),
           migration_source: "store_schema_migrations",
           priv: "priv/repo",
           journal_mode: :wal,
           busy_timeout: 5_000
         )
end
