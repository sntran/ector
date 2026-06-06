defmodule Ector.EdgeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Ector.Edge

  defmodule User do
    use Ector.Node

    schema do
      field :name, :string
    end
  end

  defmodule Cart do
    use Ector.Node

    schema do
      field :title, :string
    end
  end

  defmodule HasCart do
    use Ector.Edge

    schema do
      field :properties, :map, default: %{}

      belongs_to :user, User, role: :source
      belongs_to :cart, Cart, role: :target
    end
  end

  test "derives a screaming snake label for edge modules" do
    assert HasCart.__ector_kind__() == :edge
    assert HasCart.__ector_label__() == "HAS_CART"
    assert HasCart.__ector_table__() == :edges
    assert :__id__ in HasCart.__schema__(:fields)
  end

  test "records incoming association metadata for edge endpoints" do
    assert HasCart.__ector_associations__() == [
             %{
               cardinality: :one,
               direction: :incoming,
               name: :user,
               opts: %{role: :source},
               owner: HasCart,
               target: User
             },
             %{
               cardinality: :one,
               direction: :incoming,
               name: :cart,
               opts: %{role: :target},
               owner: HasCart,
               target: Cart
             }
           ]
  end

  test "runtime edge macro application produces the expected schema helpers" do
    module = Module.concat(__MODULE__, RuntimeEdge)

    {:module, ^module, _, _} =
      Module.create(
        module,
        quote do
          require Ector.Edge
          Ector.Edge.__using__()

          schema do
            field :weight, :integer
          end
        end,
        Macro.Env.location(__ENV__)
      )

    assert module.__ector_kind__() == :edge
    assert module.__ector_label__() == "RUNTIME_EDGE"
    assert module.__ector_associations__() == []
    assert Ecto.Changeset.get_field(module.changeset(struct(module), weight: 5), :weight) == 5
  end

  property "edge changesets preserve arbitrary property payloads without persisting __id__ input" do
    check all attrs <- edge_attrs_gen() do
      changeset = HasCart.changeset(%HasCart{}, attrs)

      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :id) == attrs["id"]
      assert Ecto.Changeset.get_change(changeset, :properties) == attrs["properties"]
      refute Map.has_key?(changeset.changes, :__id__)
    end
  end

  property "edge labels are deterministic for generated module names" do
    check all module <- module_name_gen() do
      expected = module |> Module.split() |> List.last() |> Macro.underscore() |> String.upcase()

      assert Ector.Edge.label_for(module) == expected
      assert Ector.Edge.label_for(module) == Ector.Edge.label_for(module)
    end
  end

  defp module_name_gen do
    StreamData.member_of([HasCart, User, Cart])
  end

  defp edge_attrs_gen do
    StreamData.fixed_map(%{
      "id" => string_value_gen(),
      "properties" => json_object_gen(),
      "__id__" => string_value_gen(),
      "ignored" => json_value_gen()
    })
  end

  defp json_value_gen do
    StreamData.tree(
      StreamData.one_of([
        string_value_gen(),
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
    StreamData.map_of(map_key_gen(), json_value_gen(), min_length: 1, max_length: 3)
  end

  defp string_value_gen do
    StreamData.one_of([
      hostile_string_gen(),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
    ])
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
