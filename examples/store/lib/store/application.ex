defmodule Store.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    prepare_sqlite_database!(Store.Repo)

    children = [
      Store.Repo,
      {Phoenix.PubSub, name: Store.PubSub},
      StoreWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Store.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    StoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp prepare_sqlite_database!(repo) do
    if repo.__adapter__() == Ecto.Adapters.SQLite3 do
      repo.config()
      |> Keyword.fetch!(:database)
      |> Path.dirname()
      |> File.mkdir_p!()
    end
  end
end
