defmodule Store.RelationalRepo do
  @moduledoc "Repository for the normalized relational baseline."

  @adapter Application.compile_env(:store, :repo_adapter, Ecto.Adapters.SQLite3)
  use Ecto.Repo, otp_app: :store, adapter: @adapter
end
