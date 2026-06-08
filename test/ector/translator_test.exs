defmodule Ector.TranslatorTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Ector.Migration

  @migration_version 20_260_605_100_002

  defmodule Cart do
    use Ector.Node

    schema do
      field(:title, :string)
      field(:tags, {:array, :string}, default: [])
    end
  end

  defmodule User do
    use Ector.Node

    schema do
      field(:status, :string)
      field(:metadata, :map, default: %{})
      field(:tags, {:array, :string}, default: [])
    end
  end

  defmodule CoreStorageMigration do
    use Ector.Migration
    require Ector.Migration

    def up do
      Ector.Migration.up()
    end

    def down do
      Ector.Migration.down()
    end
  end

  defmodule FakePostgresRepo do
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  defmodule FakeSQLiteRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3
  end

  defmodule FakeUnsupportedAdapter do
  end

  defmodule FakeUnsupportedRepo do
    def __adapter__, do: Ector.TranslatorTest.FakeUnsupportedAdapter
  end

  setup do
    Ector.TestRepo.drop_core_tables!()
    Ector.TestRepo.migrate!(@migration_version, CoreStorageMigration)

    on_exit(fn ->
      Ector.TestRepo.rollback!(@migration_version, CoreStorageMigration)
      Ector.TestRepo.drop_core_tables!()
    end)

    :ok
  end

  test "update_all/3 mutates only the matching label's properties JSON" do
    repo = Ector.TestRepo.repo_module()

    assert {2, nil} =
             repo.insert_all(node_insert_target(), [
               %{
                 id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
                 label: User.__ector_label__(),
                 properties:
                   encoded_properties(%{
                     "id" => "user-1",
                     "status" => "draft",
                     "metadata" => %{"tier" => "free"},
                     "tags" => ["draft"]
                   })
               },
               %{
                 id: Ecto.UUID.autogenerate(version: 7, precision: :monotonic),
                 label: Cart.__ector_label__(),
                 properties:
                   encoded_properties(%{
                     "id" => "cart-1",
                     "title" => "Pending",
                     "tags" => ["stable"]
                   })
               }
             ])

    assert {1, nil} =
             repo.update_all(User,
               set: [
                 status: "archived",
                 metadata: %{"tier" => "pro", "flags" => [true, false]},
                 tags: ["archived", "reviewed"]
               ]
             )

    assert %User{} = user = repo.one(User)
    assert user.status == "archived"
    assert user.metadata == %{"tier" => "pro", "flags" => [true, false]}
    assert user.tags == ["archived", "reviewed"]

    assert [%Cart{} = cart] = repo.all(Cart)
    assert cart.title == "Pending"
    assert cart.tags == ["stable"]
  end

  test "properties_update_expression/2 builds Postgres scalar json_set fragments" do
    assert {sql, params} = expanded_translator_output(FakePostgresRepo, status: "archived")
    assert sql =~ "jsonb_set"
    assert sql =~ "to_jsonb"

    assert [
             {%Ecto.Query.DynamicExpr{}, :any},
             {["status"], {:array, :string}},
             {"archived", :string}
           ] = params

    assert {sql, params} = expanded_translator_output(FakePostgresRepo, count: 3)
    assert sql =~ ":integer"

    assert [{%Ecto.Query.DynamicExpr{}, :any}, {["count"], {:array, :string}}, {3, :integer}] =
             params

    assert {sql, params} = expanded_translator_output(FakePostgresRepo, ratio: 1.5)
    assert sql =~ ":float"

    assert [{%Ecto.Query.DynamicExpr{}, :any}, {["ratio"], {:array, :string}}, {1.5, :float}] =
             params

    assert {sql, params} = expanded_translator_output(FakePostgresRepo, published: true)
    assert sql =~ ":boolean"

    assert [
             {%Ecto.Query.DynamicExpr{}, :any},
             {["published"], {:array, :string}},
             {true, :boolean}
           ] = params

    assert {sql, params} = expanded_translator_output(FakePostgresRepo, note: nil)
    assert sql =~ "'null'::jsonb"
    assert [{%Ecto.Query.DynamicExpr{}, :any}, {["note"], {:array, :string}}] = params
  end

  test "properties_update_expression/2 builds Postgres compound json_set fragments" do
    assert {sql, params} =
             expanded_translator_output(FakePostgresRepo, metadata: %{"tier" => "pro"})

    assert sql =~ "::text)::jsonb"

    assert [
             {%Ecto.Query.DynamicExpr{}, :any},
             {["metadata"], {:array, :string}},
             {~s({"tier":"pro"}), :any}
           ] = params

    assert {sql, params} =
             expanded_translator_output(FakePostgresRepo, tags: ["archived", "reviewed"])

    assert sql =~ "::text)::jsonb"

    assert [
             {%Ecto.Query.DynamicExpr{}, :any},
             {["tags"], {:array, :string}},
             {~s(["archived","reviewed"]), :any}
           ] = params
  end

  test "properties_update_expression/2 returns the properties field for empty generic updates" do
    assert {sql, params} = expanded_translator_output(FakePostgresRepo, [])

    assert sql =~ ".properties"
    assert params == []
  end

  test "properties_update_expression/2 builds SQLite json_set fragments" do
    assert {sql, params} =
             expanded_translator_output(FakeSQLiteRepo, metadata: %{"tier" => "pro"})

    assert sql =~ "json_set"
    refute sql =~ "%Ecto.Query.DynamicExpr{}"

    assert [{"$.metadata", :any}, {~s({"tier":"pro"}), :any}] = params

    assert {sql, params} =
             expanded_translator_output(FakeSQLiteRepo, tags: ["archived", "reviewed"])

    assert sql =~ "json_set"

    assert [{"$.tags", :any}, {~s(["archived","reviewed"]), :any}] = params
  end

  test "properties_update_expression/2 returns the SQLite properties field for empty updates" do
    assert {sql, params} = expanded_translator_output(FakeSQLiteRepo, [])

    assert sql =~ ".properties"
    assert params == []
  end

  test "properties_update_expression/2 builds one variadic SQLite json_set for multiple fields" do
    assert {sql, params} =
             expanded_translator_output(FakeSQLiteRepo,
               status: "archived",
               metadata: %{"tier" => "pro"},
               published: true
             )

    assert sql =~ "json_set"
    assert length(String.split(sql, "json(")) == 4
    assert length(String.split(sql, "json_set")) == 2

    assert [
             {"$.status", :any},
             {~s("archived"), :any},
             {"$.metadata", :any},
             {~s({"tier":"pro"}), :any},
             {"$.published", :any},
             {"true", :any}
           ] = params
  end

  test "properties_update_expression/2 rejects unsupported repos" do
    assert_raise ArgumentError, ~r/unsupported Ector adapter/, fn ->
      Ector.Translator.properties_update_expression(FakeUnsupportedRepo, status: "archived")
    end
  end

  test "properties_update_expression/2 accepts string field names" do
    assert {sql, params} = expanded_translator_output(FakeSQLiteRepo, [{"status", "archived"}])
    assert sql =~ "json_set"

    assert [{"$.status", :any}, {~s("archived"), :any}] = params
  end

  test "Postgres json_set/3 falls back to encoded jsonb for unmatched raw values" do
    expression =
      Ector.Translator.Postgres.json_set(
        dynamic([row], row.properties),
        ["opaque"],
        %{encoded: ~s({"kind":"opaque"}), raw: {:opaque, :value}}
      )

    {sql, params} = expanded_expression_output(expression)

    assert sql =~ "::jsonb"

    assert [
             {%Ecto.Query.DynamicExpr{}, :any},
             {["opaque"], {:array, :string}},
             {~s({"kind":"opaque"}), :any}
           ] = params
  end

  test "SQLite json_set/3 remains available and appends to existing fragments" do
    expression =
      Ector.Translator.SQLite.json_set(
        dynamic([row], row.properties),
        ["metadata", "tier"],
        %{encoded: ~s("pro")}
      )

    {sql, params} = expanded_expression_output(expression)

    assert sql =~ "json_set"

    assert [
             {"$.metadata.tier", :any},
             {~s("pro"), :any}
           ] = params

    expression =
      expression
      |> Ector.Translator.SQLite.json_set(["status"], %{encoded: ~s("archived")})

    {sql, params} = expanded_expression_output(expression)

    assert sql =~ "json_set"
    assert length(String.split(sql, "json(")) == 3
    assert length(String.split(sql, "json_set")) == 2

    assert [
             {"$.metadata.tier", :any},
             {~s("pro"), :any},
             {"$.status", :any},
             {~s("archived"), :any}
           ] = params
  end

  test "SQLite json_set/3 accepts raw accumulator ASTs" do
    expression =
      Ector.Translator.SQLite.json_set(
        {{:., [], [{:&, [], [0]}, :properties]}, [], []},
        ["status"],
        %{encoded: ~s("archived")}
      )

    {sql, params} = expanded_expression_output(expression)

    assert sql =~ "json_set"

    assert [
             {"$.status", :any},
             {~s("archived"), :any}
           ] = params
  end

  defp node_insert_target do
    if Ector.TestRepo.sqlite?(), do: Ector.Node.__schema__(:source), else: Ector.Node
  end

  defp encoded_properties(properties) do
    if Ector.TestRepo.sqlite?(), do: Ector.Translator.encode_json!(properties), else: properties
  end

  defp expanded_translator_output(fake_repo, updates) do
    expression = Ector.Translator.properties_update_expression(fake_repo, updates)
    expanded_expression_output(expression)
  end

  defp expanded_expression_output(expression) do
    {ast, params, [], %{}} = expression.fun.(%Ecto.Query{})

    {Macro.to_string(ast), params}
  end
end
