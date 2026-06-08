defmodule Store.EctorRepo.Migrations.CreateEctorStore do
  use Ector.Migration

  require Ector.Migration

  def up do
    Ector.Migration.up()

    create(index(Store.Ector.Product, [:sku], unique: true))
    create(index(Store.Ector.Product, [:category, :status]))
  end

  def down do
    Ector.Migration.down()
  end
end
