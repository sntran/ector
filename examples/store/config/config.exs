import Config

repo_adapter =
  case System.get_env("STORE_ADAPTER", "sqlite") do
    adapter when adapter in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
    _adapter -> Ecto.Adapters.SQLite3
  end

config :store, :repo_adapter, repo_adapter
config :store, ecto_repos: [Store.RelationalRepo, Store.EctorRepo]

config :ecto_sqlite3, :json_library, JSON
config :postgrex, :json_library, JSON

import_config "#{config_env()}.exs"
