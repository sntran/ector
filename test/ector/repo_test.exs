defmodule Ector.RepoTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Ector.Query
  require Ector.Migration

  @migration_version 20_260_605_100_001

  defmodule Cart do
    use Ector.Node

    schema do
      field(:title, :string)
    end
  end

  defmodule HasCart do
    use Ector.Edge

    schema do
      field(:status, :string)
    end
  end

  defmodule User do
    use Ector.Node

    schema do
      field(:name, :string)
      field(:metadata, :map, default: %{})

      has_many(:carts, Cart, through: :has_cart)
    end
  end

  defmodule UserWithNamedEdge do
    use Ector.Node

    schema do
      field(:name, :string)

      has_many(:carts, Cart)
    end
  end

  defmodule UserWithBinaryThrough do
    use Ector.Node

    schema do
      field(:name, :string)

      has_many(:carts, Cart, through: "has_cart")
    end
  end

  defmodule UserWithModuleThrough do
    use Ector.Node

    schema do
      field(:name, :string)

      has_many(:carts, Cart, through: HasCart)
    end
  end

  defmodule UserWithInvalidThrough do
    use Ector.Node

    schema do
      field(:name, :string)

      has_many(:carts, Cart, through: 123)
    end
  end

  defmodule PlainWidget do
    use Ecto.Schema

    @primary_key {:id, :string, []}
    schema "plain_widgets" do
      field(:name, :string)
    end
  end

  defmodule CoreStorageMigration do
    use Ector.Migration
    require Ector.Migration

    def up do
      Ector.Migration.up()

      create table(:plain_widgets, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:name, :string, null: false)
      end
    end

    def down do
      drop_if_exists(table(:plain_widgets))
      Ector.Migration.down()
    end
  end

  defmodule RejectingInsertRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3

    def insert_all(_source, _rows, _opts), do: {0, nil}
  end

  defmodule RejectingEdgeInsertRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3

    def insert_all("edges", _rows, _opts), do: {0, nil}
    def insert_all(_source, _rows, _opts), do: {1, nil}

    def transact(multi) do
      [source: {:run, run}] = Ecto.Multi.to_list(multi)

      case run.(__MODULE__, %{}) do
        {:ok, struct} -> {:ok, %{source: struct}}
        {:error, reason} -> {:error, :source, reason, %{}}
      end
    end
  end

  defmodule SuccessfulPostgresInsertRepo do
    def __adapter__, do: Ecto.Adapters.Postgres

    def insert_all(_source, _rows, _opts), do: {1, nil}
  end

  defmodule SuccessfulGenericInsertRepo do
    def __adapter__, do: :ector_generic_adapter

    def insert_all(_source, _rows, _opts), do: {1, nil}
  end

  setup do
    Ector.TestRepo.query!("DROP TABLE IF EXISTS plain_widgets")
    Ector.TestRepo.drop_core_tables!()
    Ector.TestRepo.migrate!(@migration_version, CoreStorageMigration)

    on_exit(fn ->
      Ector.TestRepo.rollback!(@migration_version, CoreStorageMigration)
      Ector.TestRepo.query!("DROP TABLE IF EXISTS plain_widgets")
      Ector.TestRepo.drop_core_tables!()
    end)

    :ok
  end

  test "insert/2 persists source target and routing edge rows" do
    repo = Ector.TestRepo.repo_module()

    source_changeset =
      User.changeset(%User{}, %{
        "id" => "user-1",
        "name" => "Ada",
        "metadata" => %{"tier" => "gold", "flags" => [true, false]}
      })

    target_changeset = Cart.changeset(%Cart{}, %{"id" => "cart-1", "title" => "Checkout"})

    source_changeset =
      Ector.Changeset.put_edge(source_changeset, :carts, [
        {target_changeset, %{"status" => "active"}}
      ])

    assert {:ok, %User{} = user} = repo.insert(source_changeset)
    assert user.id == "user-1"
    assert user.name == "Ada"
    assert user.metadata == %{"tier" => "gold", "flags" => [true, false]}
    assert is_binary(user.__id__)

    assert [%Cart{} = cart] = repo.all(Cart)
    assert cart.id == "cart-1"
    assert cart.title == "Checkout"
    assert is_binary(cart.__id__)
    refute cart.__id__ == user.__id__

    assert [%HasCart{} = edge] = repo.all(HasCart)
    assert edge.status == "active"

    node_rows =
      Ector.TestRepo.query!("SELECT label, id FROM nodes ORDER BY label, id").rows
      |> Enum.map(fn [label, hidden_id] -> [label, normalize_uuid(hidden_id)] end)

    edge_rows =
      Ector.TestRepo.query!("SELECT label, source_id, target_id FROM edges").rows
      |> Enum.map(fn [label, source_id, target_id] ->
        [label, normalize_uuid(source_id), normalize_uuid(target_id)]
      end)

    assert ["User", user.__id__] in node_rows
    assert ["Cart", cart.__id__] in node_rows
    assert edge_rows == [["HAS_CART", user.__id__, cart.__id__]]
  end

  test "insert/4 supports non-specialized adapters through the generic storage path" do
    assert {:ok, %User{} = user} =
             Ector.Repo.insert(
               SuccessfulGenericInsertRepo,
               User.changeset(%User{}, %{"id" => "user-generic", "name" => "Quinn"}),
               [],
               fn _changeset, _opts -> flunk("generic adapters should use Ector insert path") end
             )

    assert user.id == "user-generic"
    assert user.name == "Quinn"
    assert user.metadata == %{}
    assert is_binary(user.__id__)
  end

  test "all/1 and one/1 hydrate raw storage rows back into the schema struct" do
    repo = Ector.TestRepo.repo_module()
    hidden_id = Ecto.UUID.autogenerate(version: 7, precision: :monotonic)

    assert {1, nil} =
             repo.insert_all(node_insert_target(), [
               %{
                 id: hidden_id,
                 label: User.__ector_label__(),
                 properties:
                   encoded_properties(%{
                     "id" => "user-2",
                     "name" => "Lin",
                     "metadata" => %{"tier" => "pro"}
                   })
               }
             ])

    assert [%User{} = user] = repo.all(User)
    assert %User{} = hydrated_user = repo.one(User)

    assert user == hydrated_user
    assert user.id == "user-2"
    assert user.name == "Lin"
    assert user.metadata == %{"tier" => "pro"}
    assert user.__id__ == hidden_id
  end

  test "all/4 one/4 delete_all/4 and update_all/5 rewrite executable Ector queries" do
    repo = Ector.TestRepo.repo_module()
    hidden_id = Ecto.UUID.autogenerate(version: 7, precision: :monotonic)

    query =
      Ector.Query.from(user in User)
      |> Ector.Query.where([user], user.__id__ == ^hidden_id)

    assert [%User{id: "query-user", __id__: ^hidden_id}] =
             Ector.Repo.all(repo, query, [], fn executable_query, _opts ->
               assert executable_query.from.source == {"nodes", Ector.Node}
               assert hidden_id_field_access?(List.last(executable_query.wheres).expr)

               [
                 %Ector.Node{
                   id: hidden_id,
                   label: User.__ector_label__(),
                   properties: %{"id" => "query-user", "name" => "Query", "metadata" => %{}}
                 }
               ]
             end)

    projection_query = Ector.Query.select(query, [user], user.name)

    assert ["Query"] =
             Ector.Repo.all(repo, projection_query, [], fn executable_query, _opts ->
               assert executable_query.from.source == {"nodes", Ector.Node}
               assert executable_query.select
               ["Query"]
             end)

    assert %User{id: "one-query", __id__: ^hidden_id} =
             Ector.Repo.one(repo, query, [], fn executable_query, _opts ->
               assert executable_query.from.source == {"nodes", Ector.Node}

               %Ector.Node{
                 id: hidden_id,
                 label: User.__ector_label__(),
                 properties: %{"id" => "one-query", "name" => "One", "metadata" => %{}}
               }
             end)

    assert "selected" =
             Ector.Repo.one(repo, projection_query, [], fn executable_query, _opts ->
               assert executable_query.select
               "selected"
             end)

    assert {:delete, executable_query} =
             Ector.Repo.delete_all(repo, query, [], fn executable_query, _opts ->
               {:delete, executable_query}
             end)

    assert executable_query.from.source == {"nodes", Ector.Node}

    assert {:update, executable_query, [set: [properties: %Ecto.Query.DynamicExpr{}]]} =
             Ector.Repo.update_all(
               repo,
               query,
               [set: [name: "Updated"]],
               [],
               fn executable_query, updates, _opts -> {:update, executable_query, updates} end
             )

    assert executable_query.from.source == {"nodes", Ector.Node}
  end

  test "repo-boundary query rewriting handles joins and pass-through query shapes" do
    repo = Ector.TestRepo.repo_module()
    hidden_id = Ecto.UUID.autogenerate(version: 7, precision: :monotonic)

    joined_query =
      Ector.Query.from(user in User)
      |> Ector.Query.join(:carts, as: :cart)
      |> Ector.Query.where([cart: cart], cart.__id__ == ^hidden_id)

    assert [] =
             Ector.Repo.all(repo, joined_query, [], fn executable_query, _opts ->
               assert [edge_join, target_join] = executable_query.joins
               assert edge_join.source == {"edges", Ector.Edge}
               assert target_join.source == {"nodes", Ector.Node}
               assert hidden_id_field_access?(List.last(executable_query.wheres).expr)
               assert hidden_id_field_access?(target_join.on.expr)
               []
             end)

    mixed_join_query =
      Ector.Query.from(user in User)
      |> join(:inner, [user], marker in "plain_widgets", on: true)

    assert [] =
             Ector.Repo.all(repo, mixed_join_query, [], fn executable_query, _opts ->
               assert [%Ecto.Query.JoinExpr{source: {"plain_widgets", nil}}] =
                        executable_query.joins

               []
             end)

    raw_source_join_query = %{
      mixed_join_query
      | joins: [put_in(hd(mixed_join_query.joins).source, "plain_widgets")]
    }

    assert [] =
             Ector.Repo.all(repo, raw_source_join_query, [], fn executable_query, _opts ->
               assert [%Ecto.Query.JoinExpr{source: "plain_widgets"}] = executable_query.joins
               []
             end)

    nil_source_query =
      User
      |> Ector.Query.from()
      |> then(fn query -> %{query | from: %{query.from | source: {nil, User}}} end)

    assert [] =
             Ector.Repo.all(repo, nil_source_query, [], fn executable_query, _opts ->
               assert executable_query.from.source == {"nodes", Ector.Node}
               []
             end)

    assert {:fallback, %Ecto.Query{}} =
             Ector.Repo.all(repo, %Ecto.Query{}, [], fn queryable, _opts ->
               {:fallback, queryable}
             end)

    assert {:fallback, "plain_widgets"} =
             Ector.Repo.all(repo, "plain_widgets", [], fn queryable, _opts ->
               {:fallback, queryable}
             end)
  end

  test "delete/2 targets the hidden routing id instead of the domain id" do
    repo = Ector.TestRepo.repo_module()

    assert {:ok, %User{} = user} =
             repo.insert(User.changeset(%User{}, %{"id" => "user-3", "name" => "Tess"}))

    assert {:ok, %User{} = deleted_user} = repo.delete(Ecto.Changeset.change(user))
    assert deleted_user.__id__ == user.__id__

    refute repo.one(User)
    assert Ector.TestRepo.query!("SELECT COUNT(*) FROM nodes").rows == [[0]]
  end

  test "update/2 mutates domain fields through the hidden routing id" do
    repo = Ector.TestRepo.repo_module()

    assert {:ok, %User{} = user} =
             repo.insert(
               User.changeset(%User{}, %{
                 "id" => "user-update",
                 "name" => "Ada",
                 "metadata" => %{"tier" => "silver"}
               })
             )

    assert {:ok, %User{} = updated} =
             user
             |> User.changeset(%{"name" => "Ada Lovelace", "metadata" => %{"tier" => "gold"}})
             |> repo.update()

    assert updated.id == "user-update"
    assert updated.name == "Ada Lovelace"
    assert updated.metadata == %{"tier" => "gold"}
    assert updated.__id__ == user.__id__

    reloaded = repo.one(User)
    assert reloaded.id == "user-update"
    assert reloaded.name == "Ada Lovelace"
    assert reloaded.metadata == %{"tier" => "gold"}
    assert reloaded.__id__ == user.__id__
  end

  test "update/2 is a no-op when there are no domain changes" do
    repo = Ector.TestRepo.repo_module()

    assert {:ok, %User{} = user} =
             repo.insert(User.changeset(%User{}, %{"id" => "user-noop", "name" => "Lin"}))

    assert {:ok, %User{name: "Lin"}} =
             user |> Ecto.Changeset.change(%{}) |> repo.update()
  end

  test "update/2 returns invalid changesets without touching storage" do
    repo = Ector.TestRepo.repo_module()

    assert {:ok, %User{} = user} =
             repo.insert(User.changeset(%User{}, %{"id" => "user-bad-update", "name" => "Mira"}))

    invalid =
      user
      |> User.changeset(%{"name" => "Changed"})
      |> Ecto.Changeset.add_error(:name, "is invalid")

    assert {:error, returned} = repo.update(invalid)
    assert returned.errors[:name] == {"is invalid", []}

    assert %User{name: "Mira"} = repo.one(User)
  end

  test "update/4 covers edge missing id stale id and fallback paths" do
    repo = Ector.TestRepo.repo_module()

    assert {:error, edge_changeset} =
             Ector.Repo.update(
               repo,
               Ecto.Changeset.change(%HasCart{}, %{status: "active"}),
               [],
               fn _changeset, _opts -> flunk("unexpected fallback") end
             )

    assert {"only node changesets can be updated", _opts} = edge_changeset.errors[:base]

    missing_id_changeset = User.changeset(%User{}, %{"id" => "missing-update", "name" => "No ID"})

    assert {:error, missing_id_error} =
             Ector.Repo.update(repo, missing_id_changeset, [], fn _changeset, _opts ->
               flunk("unexpected fallback")
             end)

    assert {"can't be blank", _opts} = missing_id_error.errors[:__id__]

    assert {:fallback, :bogus} =
             Ector.Repo.update(repo, :bogus, [], fn value, _opts -> {:fallback, value} end)

    assert {:fallback, %Ecto.Changeset{data: %PlainWidget{id: "plain-update"}}} =
             Ector.Repo.update(
               repo,
               Ecto.Changeset.change(%PlainWidget{id: "plain-update", name: "Plain"}),
               [],
               fn value, _opts -> {:fallback, value} end
             )

    assert {:fallback, %PlainWidget{id: "plain-fallback"}} =
             Ector.Repo.insert(
               repo,
               %PlainWidget{id: "plain-fallback", name: "Plain"},
               [],
               fn value, _opts -> {:fallback, value} end
             )

    assert {:ok, %User{} = user} =
             repo.insert(User.changeset(%User{}, %{"id" => "stale-update", "name" => "Mira"}))

    stale_changeset =
      user
      |> Map.put(:__id__, Ecto.UUID.autogenerate(version: 7, precision: :monotonic))
      |> User.changeset(%{"name" => "Changed"})

    assert {:error, stale_id_error} =
             Ector.Repo.update(repo, stale_changeset, [], fn _changeset, _opts ->
               flunk("unexpected fallback")
             end)

    assert {"does not exist", _opts} = stale_id_error.errors[:__id__]
  end

  test "delete_all/2 scopes module deletes to the schema label" do
    repo = Ector.TestRepo.repo_module()

    assert {2, nil} =
             repo.insert_all(node_insert_target(), [
               %{
                 id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
                 label: User.__ector_label__(),
                 properties: encoded_properties(%{"id" => "user-4", "name" => "Mina"})
               },
               %{
                 id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
                 label: Cart.__ector_label__(),
                 properties: encoded_properties(%{"id" => "cart-2", "title" => "Saved"})
               }
             ])

    assert {1, nil} = repo.delete_all(User)
    assert [] == repo.all(User)
    assert [%Cart{id: "cart-2"}] = repo.all(Cart)
  end

  test "runtime repo macro application delegates through Ector.Repo" do
    module = Module.concat(__MODULE__, RuntimeRepo)

    {:module, ^module, _, _} =
      Module.create(
        module,
        quote do
          use Ector.Repo, otp_app: :ector, adapter: Ecto.Adapters.SQLite3
        end,
        Macro.Env.location(__ENV__)
      )

    assert module.__adapter__() == Ecto.Adapters.SQLite3
  end

  test "all/one/delete_all/update_all pass through standard Ecto queryables" do
    repo = Ector.TestRepo.repo_module()

    assert {3, nil} =
             repo.insert_all(PlainWidget, [
               %{id: "widget-1", name: "Alpha"},
               %{id: "widget-2", name: "Beta"},
               %{id: "widget-3", name: "Gamma"}
             ])

    assert [
             %PlainWidget{id: "widget-1"},
             %PlainWidget{id: "widget-2"},
             %PlainWidget{id: "widget-3"}
           ] =
             repo.all(from(widget in PlainWidget, order_by: widget.id))

    assert %PlainWidget{id: "widget-1", name: "Alpha"} =
             repo.one(from(widget in PlainWidget, where: widget.id == "widget-1"))

    assert {1, nil} =
             repo.update_all(from(widget in PlainWidget, where: widget.id == "widget-1"),
               set: [name: "Renamed"]
             )

    assert %PlainWidget{id: "widget-1", name: "Renamed"} =
             repo.one(from(widget in PlainWidget, where: widget.id == "widget-1"))

    assert {:ok, %PlainWidget{id: "widget-1", name: "Renamed"}} =
             repo.delete(
               Ecto.Changeset.change(
                 repo.one(from(widget in PlainWidget, where: widget.id == "widget-1"))
               )
             )

    assert {1, nil} = repo.delete_all(from(widget in PlainWidget, where: widget.id == "widget-2"))

    assert [%PlainWidget{id: "widget-3", name: "Gamma"}] = repo.all(PlainWidget)
  end

  test "delete/2 rejects structs with missing or stale routing ids" do
    repo = Ector.TestRepo.repo_module()

    assert {:error, missing_id_changeset} = repo.delete(%User{id: "user-missing", name: "Ghost"})
    assert {"can't be blank", _opts} = missing_id_changeset.errors[:__id__]

    assert {:ok, %User{} = user} =
             repo.insert(User.changeset(%User{}, %{"id" => "user-stale", "name" => "Mira"}))

    stale_user = %{user | __id__: Ecto.UUID.autogenerate(version: 7, precision: :monotonic)}

    assert {:error, stale_id_changeset} = repo.delete(stale_user)
    assert {"does not exist", _opts} = stale_id_changeset.errors[:__id__]
    assert %User{id: "user-stale"} = repo.one(User)
  end

  test "insert/2 returns invalid source changeset without hitting the database" do
    repo = Ector.TestRepo.repo_module()

    invalid_changeset =
      User.changeset(%User{}, %{"id" => "user-invalid", "name" => "Ada"})
      |> Ecto.Changeset.add_error(:name, "is invalid")

    assert {:error, returned_changeset} = repo.insert(invalid_changeset)
    assert returned_changeset.errors[:name] == {"is invalid", []}
    assert [] == repo.all(User)
    assert Ector.TestRepo.query!("SELECT COUNT(*) FROM nodes").rows == [[0]]
  end

  test "repo helpers hydrate storage structs and preserve projection-shaped maps" do
    repo = Ector.TestRepo.repo_module()
    hidden_id = Ecto.UUID.autogenerate(version: 7, precision: :monotonic)

    projection = %{
      id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
      properties: %{id: "user-projection", name: "Projection"}
    }

    assert [%User{} = hydrated, ^projection] =
             Ector.Repo.all(repo, User, [], fn _query, _opts ->
               [
                 %Ector.Node{
                   id: hidden_id,
                   label: User.__ector_label__(),
                   properties: %{id: "user-atom", name: "Atom", metadata: %{flags: [true, false]}}
                 },
                 projection
               ]
             end)

    assert hydrated.id == "user-atom"
    assert hydrated.name == "Atom"
    assert hydrated.metadata == %{flags: [true, false]}
    assert hydrated.__id__ == hidden_id

    assert ^projection = Ector.Repo.one(repo, User, [], fn _query, _opts -> projection end)

    assert %User{id: "edge-props", __id__: ^hidden_id} =
             Ector.Repo.one(repo, User, [], fn _query, _opts ->
               %Ector.Edge{
                 id: hidden_id,
                 label: HasCart.__ector_label__(),
                 source_id: hidden_id,
                 target_id: hidden_id,
                 properties: %{id: "edge-props", name: "Edge", metadata: %{}}
               }
             end)

    assert {:fallback, :bogus} =
             Ector.Repo.delete(repo, :bogus, [], fn value, _opts -> {:fallback, value} end)

    assert {:fallback, [inc: [name: 1]]} =
             Ector.Repo.update_all(repo, User, [inc: [name: 1]], [], fn _query, updates, _opts ->
               {:fallback, updates}
             end)
  end

  test "repo helpers preserve defaults and fall back on unsupported delete and update shapes" do
    repo = Ector.TestRepo.repo_module()

    assert [%User{id: "user-default", name: nil, metadata: %{}}] =
             Ector.Repo.all(repo, User, [], fn _query, _opts ->
               [
                 %Ector.Node{
                   id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
                   label: User.__ector_label__(),
                   properties: %{id: "user-default"}
                 }
               ]
             end)

    assert {:fallback, :bogus} =
             Ector.Repo.delete(repo, :bogus, [], fn value, _opts -> {:fallback, value} end)

    assert {:fallback, [inc: [name: 1]]} =
             Ector.Repo.update_all(repo, User, [inc: [name: 1]], [], fn _query, updates, _opts ->
               {:fallback, updates}
             end)
  end

  test "insert/2 rejects non-Ector nested targets" do
    repo = Ector.TestRepo.repo_module()

    source_changeset = User.changeset(%User{}, %{"id" => "user-invalid-target", "name" => "Ada"})
    target_changeset = Ecto.Changeset.change(%PlainWidget{id: "plain-target", name: "Widget"})

    source_changeset =
      Ector.Changeset.put_edge(source_changeset, :carts, [
        {target_changeset, %{"status" => "active"}}
      ])

    assert {:error, invalid_changeset} = repo.insert(source_changeset)
    assert {"expected an Ector schema changeset", _opts} = invalid_changeset.errors[:base]
    assert [] == repo.all(User)
  end

  test "insert/4 surfaces storage insert failures" do
    changeset = User.changeset(%User{}, %{"id" => "user-failed", "name" => "Ada"})

    assert {:error, invalid_changeset} =
             Ector.Repo.insert(RejectingInsertRepo, changeset, [], fn _struct, _opts ->
               flunk("unexpected fallback")
             end)

    assert {"expected a single storage row to be inserted", _opts} =
             invalid_changeset.errors[:base]
  end

  test "insert/4 surfaces edge insert failures" do
    source_changeset = User.changeset(%User{}, %{"id" => "user-edge-fail", "name" => "Ada"})
    target_changeset = Cart.changeset(%Cart{}, %{"id" => "cart-edge-fail", "title" => "Checkout"})

    source_changeset =
      Ector.Changeset.put_edge(source_changeset, :carts, [
        {target_changeset, %{"status" => "active"}}
      ])

    assert {:error, invalid_changeset} =
             Ector.Repo.insert(RejectingEdgeInsertRepo, source_changeset, [], fn _struct, _opts ->
               flunk("unexpected fallback")
             end)

    assert {"failed to persist edge", _opts} = invalid_changeset.errors[:carts]
  end

  test "insert/4 uses the non-SQLite storage insert path for Postgres adapters" do
    changeset = User.changeset(%User{}, %{"id" => "user-postgres", "name" => "Ada"})

    assert {:ok, %User{id: "user-postgres"}} =
             Ector.Repo.insert(SuccessfulPostgresInsertRepo, changeset, [], fn _struct, _opts ->
               flunk("unexpected fallback")
             end)
  end

  test "insert/2 supports module through labels, binary through labels, named associations, and rejects invalid edge routing metadata" do
    repo = Ector.TestRepo.repo_module()

    module_through =
      UserWithModuleThrough.changeset(%UserWithModuleThrough{}, %{
        "id" => "module-user",
        "name" => "Ada"
      })

    module_target = Cart.changeset(%Cart{}, %{"id" => "module-cart", "title" => "Checkout"})

    assert {:ok, _} =
             module_through
             |> Ector.Changeset.put_edge(:carts, [{module_target, %{"status" => "active"}}])
             |> repo.insert()

    assert Ector.TestRepo.query!("SELECT label FROM edges").rows == [[HasCart.__ector_label__()]]

    Ector.TestRepo.query!("DELETE FROM edges")
    Ector.TestRepo.query!("DELETE FROM nodes")

    binary_through =
      UserWithBinaryThrough.changeset(%UserWithBinaryThrough{}, %{
        "id" => "binary-user",
        "name" => "Ada"
      })

    binary_target = Cart.changeset(%Cart{}, %{"id" => "binary-cart", "title" => "Checkout"})

    assert {:ok, _} =
             binary_through
             |> Ector.Changeset.put_edge(:carts, [{binary_target, %{"status" => "active"}}])
             |> repo.insert()

    assert Ector.TestRepo.query!("SELECT label FROM edges").rows == [["HAS_CART"]]

    Ector.TestRepo.query!("DELETE FROM edges")
    Ector.TestRepo.query!("DELETE FROM nodes")

    named_edge =
      UserWithNamedEdge.changeset(%UserWithNamedEdge{}, %{"id" => "named-user", "name" => "Ada"})

    named_target = Cart.changeset(%Cart{}, %{"id" => "named-cart", "title" => "Checkout"})

    assert {:ok, _} =
             named_edge
             |> Ector.Changeset.put_edge(:carts, [{named_target, %{"status" => "active"}}])
             |> repo.insert()

    assert Ector.TestRepo.query!("SELECT label FROM edges").rows == [["CARTS"]]

    invalid_edge =
      UserWithInvalidThrough.changeset(%UserWithInvalidThrough{}, %{
        "id" => "bad-user",
        "name" => "Ada"
      })

    invalid_target = Cart.changeset(%Cart{}, %{"id" => "bad-cart", "title" => "Checkout"})

    assert_raise ArgumentError, ~r/unsupported Ector edge label source/, fn ->
      invalid_edge
      |> Ector.Changeset.put_edge(:carts, [{invalid_target, %{"status" => "active"}}])
      |> repo.insert()
    end
  end

  test "insert/2 raises on unknown association payload keys" do
    repo = Ector.TestRepo.repo_module()
    source_changeset = User.changeset(%User{}, %{"id" => "user-unknown", "name" => "Ada"})
    target_changeset = Cart.changeset(%Cart{}, %{"id" => "cart-unknown", "title" => "Checkout"})

    assert_raise ArgumentError, ~r/unknown Ector association/, fn ->
      source_changeset
      |> Ector.Changeset.put_edge(:unknown, [{target_changeset, %{"status" => "active"}}])
      |> repo.insert()
    end
  end

  defp normalize_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp normalize_uuid(value), do: value

  defp node_insert_target do
    if Ector.TestRepo.sqlite?(), do: Ector.Node.__schema__(:source), else: Ector.Node
  end

  defp encoded_properties(properties) do
    if Ector.TestRepo.sqlite?(), do: Ector.Translator.encode_json!(properties), else: properties
  end

  defp hidden_id_field_access?(ast) do
    ast_contains?(ast, fn
      {{:., _dot_meta, [{:&, _binding_meta, [_binding_index]}, :id]}, _call_meta, []} -> true
      _other -> false
    end)
  end

  defp ast_contains?(ast, predicate) when is_function(predicate, 1) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end
end
