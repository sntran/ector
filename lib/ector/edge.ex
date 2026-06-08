defmodule Ector.Edge do
  @moduledoc """
  Defines an Ector edge schema.

  Using `Ector.Edge` installs the Ector schema DSL for relationships stored in
  the shared `edges` table, including the hidden `__id__` routing field used to
  track graph topology independently from any business-facing identifiers.

  The module also exposes the physical `edges` table shape Ector persists so the
  storage contract stays visible in the public documentation.

  ## Example

      iex> defmodule HasCartEdge do
      ...>   use Ector.Edge
      ...>   schema do
      ...>     field :weight, :integer
      ...>   end
      ...> end
      iex> HasCartEdge.__ector_kind__()
      :edge
      iex> HasCartEdge.__ector_label__()
      "HAS_CART_EDGE"
  """

  use Ecto.Schema

  @primary_key false
  schema "edges" do
    field(:id, Ecto.UUID, primary_key: true)
    field(:label, :string)
    field(:source_id, Ecto.UUID)
    field(:target_id, Ecto.UUID)
    field(:properties, :map)
  end

  @doc false
  @spec label_for(module()) :: String.t()
  def label_for(module) when is_atom(module) do
    Ector.Schema.label_for(module, :edge)
  end

  @doc """
  Sets up the caller as an Ector edge schema.
  """
  defmacro __using__(_opts \\ []) do
    quote do
      use Ector.Schema, kind: :edge
    end
  end
end
