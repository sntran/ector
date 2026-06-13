defmodule Store.Catalog.Offer do
  @moduledoc """
  Sellable offer for a product, stored as an Ector node.

  `product_id`, `product_name`, and `product_description` are denormalized into
  the offer properties so listing and search queries stay on the offer node.
  Product images are intentionally not duplicated here.
  """

  use Ector.Node

  import Ecto.Changeset

  alias Store.Catalog.Product
  alias Store.Checkout.CartItem

  @required_fields [
    :id,
    :product_id,
    :offered_by,
    :price,
    :quantity,
    :product_name,
    :product_description
  ]

  schema do
    field(:product_id, :string)
    field(:offered_by, :string)
    field(:price, :integer)
    field(:quantity, :integer)
    field(:product_name, :string)
    field(:product_description, :string)

    belongs_to(:product, Product, define_field: false)
    has_many(:cart_items, CartItem)
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          __id__: Ecto.UUID.t() | nil,
          product_id: String.t() | nil,
          offered_by: String.t() | nil,
          price: integer() | nil,
          quantity: integer() | nil,
          product_name: String.t() | nil,
          product_description: String.t() | nil
        }

  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(offer \\ %__MODULE__{}, attrs) do
    offer
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_length(:offered_by, min: 2, max: 120)
    |> validate_number(:price, greater_than: 0)
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> validate_length(:product_name, min: 2, max: 160)
    |> validate_length(:product_description, min: 2, max: 2_000)
  end
end
