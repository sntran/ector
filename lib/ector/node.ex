defmodule Ector.Node do
  @moduledoc """
  Defines an Ector node schema.

  Using `Ector.Node` installs Ector's schema DSL, keeps the application's
  business identifier under the caller's control, and adds the hidden `__id__`
  routing field that maps onto the backend UUID topology.

  The module also exposes the physical `nodes` table shape Ector uses under the
  hood so the storage contract stays visible in the public documentation.

  ## Example

      iex> defmodule UserNode do
      ...>   use Ector.Node
      ...>   schema do
      ...>     field :email, :string
      ...>   end
      ...> end
      iex> UserNode.__ector_kind__()
      :node
      iex> UserNode.__ector_label__()
      "UserNode"
  """

  use Ecto.Schema

  @primary_key false
  schema "nodes" do
    field(:id, Ecto.UUID, primary_key: true)
    field(:label, :string)
    field(:properties, :map)
  end

  @doc false
  @spec label_for(module()) :: String.t()
  def label_for(module) when is_atom(module) do
    Ector.Schema.label_for(module, :node)
  end

  @doc """
  Sets up the caller as an Ector node schema.
  """
  defmacro __using__(_opts \\ []) do
    quote do
      use Ector.Schema, kind: :node
    end
  end
end
