defmodule Store.Ector.Customer do
  @moduledoc "schema.org/Person modeled as an Ector node."

  use Ector.Node

  alias Store.Ector.{Cart, HasCart}

  schema do
    field(:email, :string)
    field(:name, :string)

    has_many(:carts, Cart, through: HasCart)
  end

  @type t :: %__MODULE__{}
end
