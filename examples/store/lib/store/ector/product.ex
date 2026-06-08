defmodule Store.Ector.Product do
  @moduledoc """
  schema.org/Product modeled as an Ector node.

  The fields mirror `Store.Relational.Product`, but Ector persists them under
  the `Product` label in the shared `nodes.properties` JSON document.
  """

  use Ector.Node

  schema do
    field(:sku, :string)
    field(:name, :string)
    field(:category, :string)
    field(:price, :float)
    field(:status, :string, default: "active")
  end

  @type t :: %__MODULE__{}
end
