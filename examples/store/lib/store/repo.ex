defmodule Store.Repo do
  @moduledoc "Repository for the zero-migration Ector storefront."

  @adapter Application.compile_env(:store, :repo_adapter, Ecto.Adapters.SQLite3)
  use Ector.Repo, otp_app: :store, adapter: @adapter
end
