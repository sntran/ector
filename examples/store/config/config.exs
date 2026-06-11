import Config

repo_adapter =
  case System.get_env("STORE_ADAPTER", "sqlite") do
    adapter when adapter in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
    _adapter -> Ecto.Adapters.SQLite3
  end

config :store, :repo_adapter, repo_adapter
config :store, :catalog_page_size, 24
config :store, ecto_repos: [Store.Repo]

config :store, StoreWeb.Endpoint,
  render_errors: [formats: [html: StoreWeb.ErrorHTML], layout: false],
  pubsub_server: Store.PubSub,
  live_view: [signing_salt: "store_live_salt"]

config :ecto_sqlite3, :json_library, JSON
config :postgrex, :json_library, JSON
config :phoenix, :json_library, JSON

import_config "#{config_env()}.exs"
