defmodule Store.Checkout.Cart do
  @moduledoc "Checkout cart stored as an Ector node."

  use Ector.Node

  import Ecto.Changeset

  alias Store.Checkout.CartItem

  @statuses ~w(active converted abandoned)

  schema do
    field(:status, :string, default: "active")

    has_many(:items, CartItem)
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          __id__: Ecto.UUID.t() | nil,
          status: String.t() | nil
        }

  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(cart \\ %__MODULE__{}, attrs) do
    cart
    |> cast(attrs, [:id, :status])
    |> validate_required([:id, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
