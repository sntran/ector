defmodule Store.Relational.Product do
  @moduledoc """
  Normalized relational `Product` row stored in `store_products`.

  This module is the control case for `Store.Ector.Product`: every business
  attribute is represented as a physical column and indexed through ordinary
  relational migrations.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Store.Relational.CartItem

  @primary_key {:id, :string, autogenerate: false}
  schema "store_products" do
    field(:sku, :string)
    field(:name, :string)
    field(:category, :string)
    field(:price, :float)
    field(:status, :string, default: "active")

    has_many(:cart_items, CartItem)
  end

  @type t :: %__MODULE__{}

  @doc "Builds a product changeset for the relational baseline."
  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(product, attrs) when is_list(attrs), do: changeset(product, Map.new(attrs))

  def changeset(product, attrs) when is_map(attrs) do
    product
    |> cast(attrs, [:id, :sku, :name, :category, :price, :status])
    |> validate_required([:id, :sku, :name, :category, :price, :status])
  end
end
