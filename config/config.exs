import Config

config :ecto_sqlite3, :json_library, JSON
config :postgrex, :json_library, JSON

import_config "#{config_env()}.exs"
