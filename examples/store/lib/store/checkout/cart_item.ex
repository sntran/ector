defmodule Store.Checkout.CartItem do
  @moduledoc """
  Cart line item stored as an Ector node.

  `price_at_addition` snapshots the selected offer price at creation time.
  """

  use Ector.Node

  import Ecto.Changeset

  alias Store.Catalog.Offer
  alias Store.Checkout.Cart

  schema do
    field(:quantity, :integer)
    field(:price_at_addition, :integer)

    belongs_to(:cart, Cart)
    belongs_to(:offer, Offer)
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          __id__: Ecto.UUID.t() | nil,
          cart_id: Ecto.UUID.t() | nil,
          offer_id: Ecto.UUID.t() | nil,
          quantity: integer() | nil,
          price_at_addition: integer() | nil
        }

  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(cart_item \\ %__MODULE__{}, attrs) do
    cart_item
    |> cast(attrs, [:id, :cart_id, :offer_id, :quantity, :price_at_addition])
    |> validate_required([:id, :cart_id, :offer_id, :quantity, :price_at_addition])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:price_at_addition, greater_than: 0)
  end
end
