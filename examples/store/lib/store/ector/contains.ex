defmodule Store.Ector.Contains do
  @moduledoc """
  `Cart -> Product` edge carrying schema.org/OrderItem-style attributes.

  It is the graph counterpart to `Store.Relational.CartItem`.
  """

  use Ector.Edge

  schema do
    field(:quantity, :integer)
    field(:unit_price, :float)
    field(:pricing, :map, default: %{})
  end

  @type t :: %__MODULE__{}
end
