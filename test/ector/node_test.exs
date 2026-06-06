defmodule Ector.NodeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Ector.Node

  defmodule Cart do
    use Ector.Node

    schema do
      field(:total, :integer)
    end
  end

  defmodule Account do
    use Ector.Node

    schema do
      field(:status, :string)
    end
  end

  defmodule Catalog.User do
    use Ector.Node

    schema do
      field(:name, :string)
      field(:metadata, :map, default: %{})

      has_many(:carts, Cart, through: :has_cart)
      has_one(:account, Account, role: :primary)
    end
  end

  defmodule Billing.User do
    use Ector.Node

    @primary_key {:external_id, :string, []}

    schema do
      field(:status, :string)

      belongs_to(:account, Account)
    end
  end

  test "injects the default business id and hidden routing id" do
    assert :id in Catalog.User.__schema__(:fields)
    assert :__id__ in Catalog.User.__schema__(:fields)
    assert Catalog.User.__ector_kind__() == :node
    assert Catalog.User.__ector_label__() == "User"
    assert Catalog.User.__ector_table__() == :nodes
  end

  test "respects an explicit primary key declaration" do
    assert :external_id in Billing.User.__schema__(:fields)
    refute :id in Billing.User.__schema__(:fields)
    assert :__id__ in Billing.User.__schema__(:fields)
  end

  test "compiles outgoing and incoming association metadata" do
    assert Catalog.User.__ector_associations__() == [
             %{
               cardinality: :many,
               direction: :outgoing,
               name: :carts,
               opts: %{through: :has_cart},
               owner: Catalog.User,
               target: Cart
             },
             %{
               cardinality: :one,
               direction: :outgoing,
               name: :account,
               opts: %{role: :primary},
               owner: Catalog.User,
               target: Account
             }
           ]

    assert Billing.User.__ector_associations__() == [
             %{
               cardinality: :one,
               direction: :incoming,
               name: :account,
               opts: %{},
               owner: Billing.User,
               target: Account
             }
           ]
  end

  test "distinct modules can share the same logical label without merging schema identity" do
    assert Catalog.User.__ector_label__() == Billing.User.__ector_label__()
    assert Atom.to_string(Catalog.User) != Atom.to_string(Billing.User)
    assert Catalog.User.__schema__(:fields) != Billing.User.__schema__(:fields)
  end

  test "changeset accepts keyword lists, preserves existing __id__, and handles invalid attrs" do
    existing_id = Ecto.UUID.autogenerate(version: 7)

    keyword_changeset = Catalog.User.changeset(%Catalog.User{}, name: "Ada")
    invalid_changeset = Catalog.User.changeset(%Catalog.User{__id__: existing_id}, :invalid)

    assert keyword_changeset.valid?
    assert Ecto.Changeset.get_field(keyword_changeset, :name) == "Ada"
    refute Map.has_key?(keyword_changeset.changes, :__id__)
    assert Ecto.Changeset.get_field(invalid_changeset, :__id__) == existing_id
  end

  test "runtime node macro application produces the expected schema helpers" do
    module = Module.concat(__MODULE__, RuntimeNode)

    {:module, ^module, _, _} =
      Module.create(
        module,
        quote do
          require Ector.Node
          Ector.Node.__using__()

          schema do
            field(:name, :string)
          end
        end,
        Macro.Env.location(__ENV__)
      )

    assert module.__ector_kind__() == :node
    assert module.__ector_label__() == "RuntimeNode"
    assert module.__ector_associations__() == []
    assert Ecto.Changeset.get_field(module.changeset(struct(module), name: "Lin"), :name) == "Lin"
  end

  property "changeset preserves arbitrary node payloads without persisting __id__ input" do
    check all(attrs <- node_attrs_gen()) do
      changeset = Catalog.User.changeset(%Catalog.User{}, attrs)

      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :id) == attrs["id"]
      assert Ecto.Changeset.get_change(changeset, :name) == attrs["name"]
      assert Ecto.Changeset.get_change(changeset, :metadata) == attrs["metadata"]
      refute Map.has_key?(changeset.changes, :__id__)
    end
  end

  property "node labels are deterministic for generated module names" do
    check all(module <- module_name_gen()) do
      assert Ector.Node.label_for(module) == module |> Module.split() |> List.last()
      assert Ector.Node.label_for(module) == Ector.Node.label_for(module)
    end
  end

  defp node_attrs_gen do
    StreamData.fixed_map(%{
      "id" => string_value_gen(),
      "name" => string_value_gen(),
      "metadata" => json_object_gen(),
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
          StreamData.list_of(inner, max_length: 4),
          StreamData.map_of(map_key_gen(), inner, max_length: 4)
        ])
      end
    )
  end

  defp json_object_gen do
    StreamData.map_of(map_key_gen(), json_value_gen(), min_length: 1, max_length: 4)
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

  defp module_name_gen do
    StreamData.member_of([Catalog.User, Billing.User, Cart, Account])
  end
end
