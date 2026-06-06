defmodule Ector.Node do
	@moduledoc """
	Defines an Ector node schema.

	Using `Ector.Node` installs Ector's schema DSL, keeps the application's
	business identifier under the caller's control, and adds the hidden `__id__`
	routing field that maps onto the backend UUID topology.

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

	@doc """
	Derives the logical label stored for a node module in the shared `nodes` table.

	## Examples

	    iex> Ector.Node.label_for(MyApp.Checkout.Cart)
	    "Cart"
	"""
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
