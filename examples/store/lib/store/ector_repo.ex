defmodule Store.EctorRepo do
  @moduledoc "Repository for the Ector graph/JSON engine baseline."

  @adapter Application.compile_env(:store, :repo_adapter, Ecto.Adapters.SQLite3)
  use Ector.Repo, otp_app: :store, adapter: @adapter
end
