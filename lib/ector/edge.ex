defmodule Ector.Edge do
	@moduledoc """
	Defines an Ector edge schema.

	Using `Ector.Edge` installs the Ector schema DSL for relationships stored in
	the shared `edges` table, including the hidden `__id__` routing field used to
	track graph topology independently from any business-facing identifiers.

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

	@doc """
	Derives the logical label stored for an edge module in the shared `edges` table.

	## Examples

	    iex> Ector.Edge.label_for(MyApp.Checkout.HasCart)
	    "HAS_CART"
	"""
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
