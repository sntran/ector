defmodule Ector.Changeset do
  @moduledoc """
  Helpers for assembling graph inserts before they reach `Ector.Repo`.

  Ector uses a tuple payload strategy for nested graph writes: each association
  entry carries a target changeset plus the properties that belong on the edge
  connecting it to the source node.
  """

  alias Ecto.Changeset

  @typedoc "Associates target node changesets with edge properties."
  @type json_value ::
          String.t() | number() | boolean() | nil | [json_value()] | %{String.t() => json_value()}
  @type edge_properties :: %{String.t() => json_value()}
  @type edge_payload :: [{Changeset.t(), edge_properties()}]

  @doc """
  Stores edge payload tuples under an association name on a changeset.

  Each tuple is `{target_changeset, edge_properties}`. `Ector.Repo.insert/1`
  uses the accumulated `__ector_edges__` metadata to insert the target node and
  then materialize the connecting edge with the provided properties.

  ## Examples

      iex> defmodule UserNode do
      ...>   use Ector.Node
      ...>   schema do
      ...>     field :name, :string
      ...>   end
      ...> end
      iex> defmodule CartNode do
      ...>   use Ector.Node
      ...>   schema do
      ...>     field :title, :string
      ...>   end
      ...> end
      iex> source = UserNode.changeset(struct(UserNode), %{name: "Ada"})
      iex> target = CartNode.changeset(struct(CartNode), %{title: "Checkout"})
      iex> updated = Ector.Changeset.put_edge(source, :carts, [{target, %{"status" => "active"}}])
      iex> updated.changes.__ector_edges__[:carts]
      ...> |> Enum.map(fn {cart_changeset, edge_props} ->
      ...>   {Ecto.Changeset.get_change(cart_changeset, :title), edge_props}
      ...> end)
      [{"Checkout", %{"status" => "active"}}]
  """
  @spec put_edge(Changeset.t(), atom(), edge_payload()) :: Changeset.t()
  def put_edge(%Changeset{} = changeset, assoc_name, targets_with_props)
      when is_atom(assoc_name) and is_list(targets_with_props) do
    Enum.each(targets_with_props, fn
      {%Changeset{}, edge_properties} when is_map(edge_properties) ->
        :ok

      invalid_payload ->
        raise ArgumentError,
              "expected edge payload entries to be {Ecto.Changeset.t(), map()}, got: #{inspect(invalid_payload)}"
    end)

    existing_edges = Map.get(changeset.changes, :__ector_edges__, %{})
    updated_edges = Map.put(existing_edges, assoc_name, targets_with_props)

    %{changeset | changes: Map.put(changeset.changes, :__ector_edges__, updated_edges)}
  end
end
