defmodule Store.Ector.Cart do
  @moduledoc """
  schema.org/Order in its cart phase, modeled as an Ector node.

  Products are reached through `Store.Ector.Contains` edges rather than a join
  table, which lets the graph shape evolve without relational table changes.
  """

  use Ector.Node

  alias Store.Ector.{Contains, Product}

  schema do
    field(:status, :string, default: "active")
    field(:currency, :string, default: "USD")

    has_many(:items, Product, through: Contains)
  end

  @type t :: %__MODULE__{}
end
