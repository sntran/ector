defmodule Store.Relational.Cart do
  @moduledoc """
  Normalized relational cart row stored in `store_carts`.

  A cart belongs to a customer and owns `Store.Relational.CartItem` rows that
  model the product association and its per-item attributes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Store.Relational.{CartItem, Customer}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  schema "store_carts" do
    field(:status, :string, default: "active")
    field(:currency, :string, default: "USD")

    belongs_to(:customer, Customer)
    has_many(:cart_items, CartItem)
  end

  @type t :: %__MODULE__{}

  @doc "Builds a cart changeset for the relational baseline."
  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(cart, attrs) when is_list(attrs), do: changeset(cart, Map.new(attrs))

  def changeset(cart, attrs) when is_map(attrs) do
    cart
    |> cast(attrs, [:id, :customer_id, :status, :currency])
    |> validate_required([:id, :customer_id, :status, :currency])
  end
end
