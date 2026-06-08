defmodule Store.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Store.RelationalRepo, Store.EctorRepo]

    Enum.each(children, &prepare_sqlite_database!/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: Store.Supervisor)
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
