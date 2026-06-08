defmodule Store.Relational.Customer do
  @moduledoc """
  Normalized relational customer row stored in `store_customers`.

  The schema mirrors `Store.Ector.Customer` while using a conventional
  one-to-many relationship to carts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Store.Relational.Cart

  @primary_key {:id, :string, autogenerate: false}
  schema "store_customers" do
    field(:email, :string)
    field(:name, :string)

    has_many(:carts, Cart)
  end

  @type t :: %__MODULE__{}

  @doc "Builds a customer changeset for the relational baseline."
  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(customer, attrs) when is_list(attrs), do: changeset(customer, Map.new(attrs))

  def changeset(customer, attrs) when is_map(attrs) do
    customer
    |> cast(attrs, [:id, :email, :name])
    |> validate_required([:id, :email, :name])
  end
end
