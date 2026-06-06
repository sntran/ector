import Config

config :ector, Ector.TestRepo.SQLite,
  database: Path.join(System.tmp_dir!(), "ector_dev.sqlite3"),
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5_000,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  migration_source: "ector_schema_migrations"
