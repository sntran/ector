defmodule Store.RelationalRepo.Migrations.CreateRelationalStore do
  use Ecto.Migration

  def change do
    create table(:store_products, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:sku, :string, null: false)
      add(:name, :string, null: false)
      add(:category, :string, null: false)
      add(:price, :float, null: false)
      add(:status, :string, null: false, default: "active")
    end

    create(unique_index(:store_products, [:sku]))
    create(index(:store_products, [:category, :status]))

    create table(:store_customers, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:email, :string, null: false)
      add(:name, :string, null: false)
    end

    create(unique_index(:store_customers, [:email]))

    create table(:store_carts, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:customer_id, references(:store_customers, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:status, :string, null: false, default: "active")
      add(:currency, :string, null: false, default: "USD")
    end

    create(index(:store_carts, [:customer_id]))
    create(index(:store_carts, [:status]))

    create table(:store_cart_items) do
      add(:cart_id, references(:store_carts, type: :string, on_delete: :delete_all), null: false)

      add(:product_id, references(:store_products, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:quantity, :integer, null: false)
      add(:unit_price, :float, null: false)
    end

    create(index(:store_cart_items, [:cart_id]))
    create(index(:store_cart_items, [:product_id]))
    create(unique_index(:store_cart_items, [:cart_id, :product_id]))
  end
end
