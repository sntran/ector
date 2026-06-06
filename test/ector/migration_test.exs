defmodule Ector.MigrationTest do
  use ExUnit.Case, async: false

  require Ector.Migration

  @migration_version 20_260_604_000_001

  defmodule IndexUser do
    use Ector.Node

    schema do
      field :email, :string
    end
  end

  defmodule QuotedLabelNode do
    def __ector_kind__, do: :node
    def __ector_label__, do: "Quote'Label"
    def __ector_table__, do: :nodes
  end

  defmodule NullByteLabelNode do
    def __ector_kind__, do: :node
    def __ector_label__, do: "null\0byte"
    def __ector_table__, do: :nodes
  end

  defmodule CommentLabelNode do
    def __ector_kind__, do: :node
    def __ector_label__, do: "label--comment"
    def __ector_table__, do: :nodes
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

  setup do
    Ector.TestRepo.drop_core_tables!()
    Ector.TestRepo.migrate!(@migration_version, CoreStorageMigration)

    on_exit(fn ->
      Ector.TestRepo.rollback!(@migration_version, CoreStorageMigration)
      Ector.TestRepo.drop_core_tables!()
    end)

    :ok
  end

  test "up/0 creates the core storage tables and columns" do
    assert Ector.TestRepo.table_exists?("nodes")
    assert Ector.TestRepo.table_exists?("edges")

    assert Ector.TestRepo.column_names("nodes") == ["id", "label", "properties"]
    assert Ector.TestRepo.column_names("edges") == ["id", "label", "source_id", "target_id", "properties"]

    if Ector.TestRepo.postgres?() do
      assert Ector.TestRepo.column_type("nodes", "id") == "uuid"
      assert Ector.TestRepo.column_type("edges", "source_id") == "uuid"
    end
  end

  test "up/0 creates the expected adapter-specific indexes" do
    assert "nodes_label_index" in Ector.TestRepo.index_names("nodes")
    assert "edges_source_id_index" in Ector.TestRepo.index_names("edges")
    assert "edges_target_id_index" in Ector.TestRepo.index_names("edges")
    assert "edges_source_id_label_index" in Ector.TestRepo.index_names("edges")
    refute "edges_label_source_id_target_id_index" in Ector.TestRepo.index_names("edges")

    if Ector.TestRepo.postgres?() do
      assert "nodes_properties_gin" in Ector.TestRepo.index_names("nodes")
      assert Ector.TestRepo.index_sql("nodes_properties_gin") =~ "USING gin (properties)"
    else
      refute "nodes_properties_gin" in Ector.TestRepo.index_names("nodes")
    end
  end

  test "index/3 rewrites schema fields into partial JSON property indexes" do
    index = Ector.Migration.index(Ector.MigrationTest.IndexUser, [:email], prefix: "tenant_alpha", unique: true)

    assert to_string(index.table) == "nodes"
    assert index.columns == ["(properties->>'email')"]
    # Shared storage means expression indexes must be fenced to one logical label.
    assert index.where == "label = 'IndexUser'"
    assert index.prefix == "tenant_alpha"
    assert index.unique
  end

  test "index/3 safely escapes quoted labels and quoted property keys" do
    index = Ector.Migration.index(Ector.MigrationTest.QuotedLabelNode, [:email, :"quote'field"])

    assert index.columns == ["(properties->>'email')", "(properties->>'quote''field')"]
    assert index.where == "label = 'Quote''Label'"
  end

  test "up/0 embeds a safely escaped prefixed gin statement during macro expansion" do
    expanded =
      Macro.expand_once(
        quote do
          Ector.Migration.up(prefix: "tenant\"alpha")
        end,
        __ENV__
      )

    {_, string_literals} =
      Macro.prewalk(expanded, [], fn
        value, acc when is_binary(value) -> {value, [value | acc]}
        node, acc -> {node, acc}
      end)

    assert "CREATE INDEX IF NOT EXISTS nodes_properties_gin ON \"tenant\"\"alpha\".\"nodes\" USING GIN (properties)" in
             string_literals
  end

  test "index/3 rejects null bytes" do
    assert_raise ArgumentError, ~r/SQL string literal cannot contain null bytes/, fn ->
      Code.eval_quoted(
        quote do
          Ector.Migration.index(Ector.MigrationTest.NullByteLabelNode, [:email])
        end,
        [],
        __ENV__
      )
    end
  end

  test "index/3 rejects SQL comment sequences" do
    # The validation pipeline rejects line and block comment tokens before any
    # caller-controlled fragment is interpolated into migration SQL.
    assert_raise ArgumentError, ~r/SQL string literal cannot contain SQL comment sequences/, fn ->
      Code.eval_quoted(
        quote do
          Ector.Migration.index(Ector.MigrationTest.CommentLabelNode, [:email])
        end,
        [],
        __ENV__
      )
    end

    assert_raise ArgumentError, ~r/index expression cannot contain SQL comment sequences/, fn ->
      Code.eval_quoted(
        quote do
          Ector.Migration.index(Ector.MigrationTest.IndexUser, ["lower(email) -- injected"])
        end,
        [],
        __ENV__
      )
    end

    assert_raise ArgumentError, ~r/index WHERE clause cannot contain SQL comment sequences/, fn ->
      Code.eval_quoted(
        quote do
          Ector.Migration.index(Ector.MigrationTest.IndexUser, [:email], where: "active = TRUE -- injected")
        end,
        [],
        __ENV__
      )
    end
  end

  test "runtime migration macro application covers raw-table and special-column paths" do
    module = Module.concat(__MODULE__, RuntimeMigration)

    {:module, ^module, _, _} =
      Module.create(
        module,
        quote do
          require Ector.Migration
          Ector.Migration.__using__()
          require Ector.Migration

          def build_indexes do
            {
              Ector.Migration.index("audit_logs", ["lower(actor)"], prefix: "tenant_alpha"),
              Ector.Migration.index(:edges, [:source_id, :target_id]),
              Ector.Migration.index(
                Ector.MigrationTest.IndexUser,
                [:label, :id, :source_id, :target_id, :__id__],
                where: "active = TRUE"
              ),
              Ector.Migration.index(
                Ector.MigrationTest.IndexUser,
                [desc: :label],
                where: "verified = TRUE"
              ),
              Ector.Migration.index(Ector.MigrationTest.IndexUser, [desc: "lower(email)"]),
              Ector.Migration.index(Ector.MigrationTest.IndexUser, ["lower(email)"])
            }
          end
        end,
        Macro.Env.location(__ENV__)
      )

    {binary_table_index, atom_table_index, schema_index, directional_index, directional_expression_index, expression_index} =
      module.build_indexes()

    assert to_string(binary_table_index.table) == "audit_logs"
    assert binary_table_index.columns == ["lower(actor)"]
    assert binary_table_index.prefix == "tenant_alpha"

    assert to_string(atom_table_index.table) == "edges"
    assert atom_table_index.columns == [:source_id, :target_id]

    assert schema_index.columns == [:label, :id, :source_id, :target_id, :id]
    assert schema_index.where == "(active = TRUE) AND label = 'IndexUser'"

    assert directional_index.columns == [[desc: :label]]
    assert directional_index.where == "(verified = TRUE) AND label = 'IndexUser'"

    assert directional_expression_index.columns == ["lower(email) DESC"]
    assert directional_expression_index.where == "label = 'IndexUser'"

    assert expression_index.columns == ["lower(email)"]
    assert expression_index.where == "label = 'IndexUser'"
  end

  test "down/0 removes the core tables" do
    Ector.TestRepo.rollback!(@migration_version, CoreStorageMigration)

    refute Ector.TestRepo.table_exists?("nodes")
    refute Ector.TestRepo.table_exists?("edges")
  end
end
