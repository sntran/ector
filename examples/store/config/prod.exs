import Config

config :store,
       Store.RelationalRepo,
       url: System.fetch_env!("STORE_RELATIONAL_DATABASE_URL"),
       pool_size: String.to_integer(System.get_env("STORE_POOL_SIZE") || "10"),
       migration_source: "store_relational_schema_migrations",
       priv: "priv/relational_repo"

config :store,
       Store.EctorRepo,
       url: System.fetch_env!("STORE_ECTOR_DATABASE_URL"),
       pool_size: String.to_integer(System.get_env("STORE_POOL_SIZE") || "10"),
       migration_source: "store_ector_schema_migrations",
       priv: "priv/ector_repo"
