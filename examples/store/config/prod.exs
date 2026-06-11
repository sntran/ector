import Config

config :store, StoreWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: String.to_integer(System.get_env("PORT") || "4000")
  ],
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: true

config :store,
       Store.Repo,
       url: System.fetch_env!("STORE_DATABASE_URL"),
       pool_size: String.to_integer(System.get_env("STORE_POOL_SIZE") || "10"),
       migration_source: "store_schema_migrations",
       priv: "priv/repo"
