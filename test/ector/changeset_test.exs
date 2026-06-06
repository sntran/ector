defmodule Ector.ChangesetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Ector.Changeset

  defmodule User do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  defmodule Cart do
    use Ector.Node

    schema do
      field(:title, :string)
    end
  end

  test "put_edge stores validated payloads under the association key" do
    source = User.changeset(%User{}, %{"name" => "Ada"})
    target = Cart.changeset(%Cart{}, %{"title" => "Checkout"})

    updated = Ector.Changeset.put_edge(source, :carts, [{target, %{"status" => "active"}}])

    assert updated.valid?
    assert updated.changes.__ector_edges__[:carts] == [{target, %{"status" => "active"}}]
  end

  test "put_edge rejects malformed payload tuples" do
    source = User.changeset(%User{}, %{"name" => "Ada"})

    assert_raise ArgumentError, ~r/expected edge payload entries/, fn ->
      Ector.Changeset.put_edge(source, :carts, [{:invalid, %{}}])
    end
  end

  property "put_edge preserves arbitrary edge property maps" do
    check all(edge_properties <- json_object_gen()) do
      source = User.changeset(%User{}, %{"name" => "Ada"})
      target = Cart.changeset(%Cart{}, %{"title" => "Checkout"})

      updated = Ector.Changeset.put_edge(source, :carts, [{target, edge_properties}])

      assert updated.valid?
      assert updated.changes.__ector_edges__[:carts] == [{target, edge_properties}]
    end
  end

  defp json_value_gen do
    StreamData.tree(
      StreamData.one_of([
        StreamData.binary(),
        hostile_string_gen(),
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.constant(nil)
      ]),
      fn inner ->
        StreamData.one_of([
          StreamData.list_of(inner, max_length: 3),
          StreamData.map_of(map_key_gen(), inner, max_length: 3)
        ])
      end
    )
  end

  defp json_object_gen do
    StreamData.map_of(map_key_gen(), json_value_gen(), max_length: 4)
  end

  defp map_key_gen do
    StreamData.one_of([
      hostile_string_gen(),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
    ])
  end

  defp hostile_string_gen do
    StreamData.member_of([
      "x' OR TRUE --",
      "quote\"name",
      "null\0byte",
      "line\nbreak",
      "unicode-ü-☃"
    ])
  end
end
