import Config

postgres? = System.get_env("STORE_ADAPTER") in ["postgres", "postgresql"]

common = [
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 2,
  log: false
]

config :store, StoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base:
    "store_dev_secret_key_base_64_bytes_minimum_for_signed_live_sessions_1234567890"

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
           database: Path.join(tmp, "store_dev.sqlite3"),
           migration_source: "store_schema_migrations",
           priv: "priv/repo",
           journal_mode: :wal,
           busy_timeout: 5_000
         )
end
