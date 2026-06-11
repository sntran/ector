defmodule Store.Repo.Migrations.InstallEctorEngine do
  use Ector.Migration

  def up do
    Ector.Migration.up()
  end

  def down do
    Ector.Migration.down()
  end
end
