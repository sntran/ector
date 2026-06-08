defmodule Store.Ector.HasCart do
  @moduledoc "Customer -> Cart edge for an in-progress checkout session."

  use Ector.Edge

  schema do
    field(:created_via, :string)
  end

  @type t :: %__MODULE__{}
end
