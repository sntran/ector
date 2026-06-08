defmodule Store.Relational.CartItem do
  @moduledoc """
  Join row between relational carts and products.

  This table is the normalized counterpart to the Ector `CONTAINS` edge.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Store.Relational.{Cart, Product}

  @foreign_key_type :string
  schema "store_cart_items" do
    field(:quantity, :integer)
    field(:unit_price, :float)

    belongs_to(:cart, Cart)
    belongs_to(:product, Product)
  end

  @type t :: %__MODULE__{}

  @doc "Builds a cart item changeset for the relational baseline."
  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(cart_item, attrs) when is_list(attrs), do: changeset(cart_item, Map.new(attrs))

  def changeset(cart_item, attrs) when is_map(attrs) do
    cart_item
    |> cast(attrs, [:cart_id, :product_id, :quantity, :unit_price])
    |> validate_required([:cart_id, :product_id, :quantity, :unit_price])
  end
end
