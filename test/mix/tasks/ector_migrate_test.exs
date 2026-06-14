defmodule Mix.Tasks.Ector.MigrateTest do
  use ExUnit.Case, async: false

  setup do
    previous_shell = Mix.shell()
    previous_repos = Application.get_env(:ector, :ecto_repos, :__ector_migrate_unset__)

    Mix.shell(Mix.Shell.Process)
    Application.put_env(:ector, :ecto_repos, [Ector.TestRepo.repo_module()])

    on_exit(fn ->
      Mix.shell(previous_shell)
      restore_app_env(:ector, :ecto_repos, previous_repos)
    end)

    :ok
  end

  test "dry-run does not write schema files and write mode preserves schema macros" do
    suffix = unique_suffix()
    user_module = Module.concat([Ector.MigrateFixture, "AstUser#{suffix}"])
    post_module = Module.concat([Ector.MigrateFixture, "AstPost#{suffix}"])

    source = """
    defmodule #{inspect(user_module)} do
      use Ecto.Schema
      import Ecto.Changeset

      schema "legacy_users" do
        field(:name, :string)
        has_many(:posts, #{inspect(post_module)}, foreign_key: :user_id)
      end

      def query_helpers(record, attrs) do
        alias Ecto.Repo

        preloaded = Ecto.Repo.preload(record, :posts)
        query = Ecto.Query.from(p in #{inspect(post_module)}, select: p.name)
        changeset = Ecto.Changeset.cast(record, attrs, [:name])

        {Repo, preloaded, query, changeset}
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/legacy_user.ex", source)

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--dry-run"])
      assert File.read!(path) == source

      assert :ok = Mix.Tasks.Ector.Migrate.run([])
      migrated = File.read!(path)

      assert migrated =~ "use Ector.Node"
      assert migrated =~ "alias Ector.Repo"
      assert migrated =~ "Ector.Repo.preload(record, :posts)"
      assert migrated =~ "Ector.Query.from(p in #{inspect(post_module)}, select: p.name)"
      assert migrated =~ "import Ecto.Changeset"
      assert migrated =~ "Ecto.Changeset.cast(record, attrs, [:name])"
      refute migrated =~ "Ector.Changeset"
      assert migrated =~ ~s(schema "legacy_users" do)
      assert migrated =~ "has_many(:posts, #{inspect(post_module)}, foreign_key: :user_id)"
    end)
  end

  test "dry-run data mode reports that backfill is skipped" do
    suffix = unique_suffix()
    module = Module.concat([Ector.MigrateFixture, "DryRunData#{suffix}"])

    source = """
    defmodule #{inspect(module)} do
      use Ecto.Schema

      schema "legacy_dry_run_data_#{suffix}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/dry_run_data.ex", source)

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--dry-run", "--data"])
      assert File.read!(path) == source

      assert_received {:mix_shell, :info, ["Skipping data backfill because --dry-run is active"]}
    end)
  end

  test "quoted Ecto schema references are ignored by the AST mutator" do
    source = """
    defmodule Ector.MigrateFixture.QuotedSchemaReference do
      def quoted_schema do
        quote do
          use Ecto.Schema
        end
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/quoted_schema_reference.ex", source)

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--dry-run"])
      assert File.read!(path) == source
    end)
  end

  test "AST discovery tolerates atom modules dynamic modules and spaced schema aliases" do
    suffix = unique_suffix()

    source = """
    defmodule :"Elixir.Ector.MigrateFixture.AtomSchema#{suffix}" do
      use Ecto.Schema

      schema "legacy_atom_schemas_#{suffix}" do
        field(:name, :string)
      end
    end

    defmodule Module.concat([Ector.MigrateFixture, DynamicSchema#{suffix}]) do
      use Ecto.Schema

      schema "legacy_dynamic_schemas_#{suffix}" do
        field(:name, :string)
      end
    end

    defmodule Ector.MigrateFixture.SpacedSchema#{suffix} do
      use Ecto . Schema

      schema "legacy_spaced_schemas_#{suffix}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/ast_shapes.ex", source)

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--dry-run"])
      assert File.read!(path) == source
    end)
  end

  test "invalid source files are reported with their path" do
    in_tmp_project(fn ->
      write_schema_file!("lib/broken_schema.ex", "defmodule BrokenSchema do\n  use Ecto.Schema\n")

      error =
        assert_raise RuntimeError, fn ->
          Mix.Tasks.Ector.Migrate.run(["--dry-run"])
        end

      assert Exception.message(error) =~ "failed to process lib/broken_schema.ex"
    end)
  end

  test "data backfill reports migrated schema modules that were not loaded" do
    suffix = unique_suffix()
    module = Module.concat([Ector.MigrateFixture, "Unloaded#{suffix}"])

    source = """
    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "legacy_unloaded_#{suffix}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      write_schema_file!("lib/unloaded.ex", source)
      reset_storage!()

      on_exit(fn -> reset_storage!() end)

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Ector.Migrate.run(["--data"])
        end

      assert Exception.message(error) =~ "Could not load schema module #{inspect(module)}"
    end)
  end

  test "data backfill is a no-op when no schemas were migrated" do
    in_tmp_project(fn ->
      write_schema_file!("lib/plain_module.ex", """
      defmodule Ector.MigrateFixture.PlainModule do
        def ok, do: :ok
      end
      """)

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--data"])
    end)
  end

  test "data backfill requires a repo when migrated schemas are present" do
    suffix = unique_suffix()
    module = Module.concat([Ector.MigrateFixture, "NoRepo#{suffix}"])
    repo = Ector.TestRepo.repo_module()
    previous_repo_config = Application.fetch_env!(:ector, repo)

    source = """
    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "legacy_no_repo_#{suffix}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/no_repo.ex", source)
      Code.compile_file(path)

      Application.put_env(:ector, :ecto_repos, [])

      try do
        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Ector.Migrate.run(["--data"])
          end

        assert Exception.message(error) =~
                 "No Ecto repos found for application :ector; pass --repo MyApp.Repo"
      after
        Application.put_env(:ector, :ecto_repos, [repo])
        Application.put_env(:ector, repo, previous_repo_config)
      end
    end)
  end

  test "data backfill auto-detects repo from application config when --repo is not provided" do
    suffix = unique_suffix()
    module = Module.concat([Ector.MigrateFixture, "AutoDetectRepo#{suffix}"])
    repo = Ector.TestRepo.repo_module()
    previous_repo_config = Application.fetch_env!(:ector, repo)

    schema_source = """
    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "legacy_auto_detect_#{suffix}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/auto_detect.ex", schema_source)
      Code.compile_file(path)

      table = "legacy_auto_detect_#{suffix}"
      reset_storage!()
      create_name_table!(table)

      on_exit(fn ->
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{table}")
        reset_storage!()
      end)

      previous_repos = Application.get_env(:ector, :ecto_repos)

      try do
        # 1. Exactly one repo
        Application.put_env(:ector, :ecto_repos, [repo])
        assert :ok = Mix.Tasks.Ector.Migrate.run(["--data"])

        # 2. Multiple repos
        write_schema_file!("lib/auto_detect.ex", schema_source)
        Application.put_env(:ector, :ecto_repos, [repo, Ector.OtherRepo])

        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Ector.Migrate.run(["--data"])
          end

        assert Exception.message(error) =~
                 "Multiple Ecto repos found for application :ector; pass --repo MyApp.Repo"

        # 3. Empty list
        write_schema_file!("lib/auto_detect.ex", schema_source)
        Application.put_env(:ector, :ecto_repos, [])

        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Ector.Migrate.run(["--data"])
          end

        assert Exception.message(error) =~
                 "No Ecto repos found for application :ector; pass --repo MyApp.Repo"

        # 4. Nil (Not configured)
        write_schema_file!("lib/auto_detect.ex", schema_source)
        Application.delete_env(:ector, :ecto_repos)

        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Ector.Migrate.run(["--data"])
          end

        assert Exception.message(error) =~
                 "No Ecto repos found for application :ector; pass --repo MyApp.Repo"

        # 5. Missing Mix Project (Nil app)
        current_project = Mix.Project.get()
        Mix.Project.pop()

        try do
          write_schema_file!("lib/auto_detect.ex", schema_source)

          error =
            assert_raise Mix.Error, fn ->
              Mix.Tasks.Ector.Migrate.run(["--data"])
            end

          assert Exception.message(error) =~
                   "Could not auto-detect application name; pass --repo MyApp.Repo"
        after
          if current_project, do: Mix.Project.push(current_project)
        end

        # 6. Explicitly empty `--repo ""` flag
        write_schema_file!("lib/auto_detect.ex", schema_source)

        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Ector.Migrate.run(["--data", "--repo", ""])
          end

        assert Exception.message(error) =~
                 "Cannot run --data without an Ecto repo; pass --repo MyApp.Repo"
      after
        if previous_repos,
          do: Application.put_env(:ector, :ecto_repos, previous_repos),
          else: Application.delete_env(:ector, :ecto_repos)

        Application.put_env(:ector, repo, previous_repo_config)
      end
    end)
  end

  test "data backfill reports repo startup failures" do
    suffix = unique_suffix()
    module = Module.concat([Ector.MigrateFixture, "RepoStartFailure#{suffix}"])
    repo = Module.concat([Ector.MigrateFixture, "FailingRepo#{suffix}"])
    adapter = Module.concat([Ector.MigrateFixture, "FailingAdapter#{suffix}"])
    repo_name = repo |> Module.split() |> Enum.join(".")

    source = """
    defmodule #{inspect(adapter)} do
      def ensure_all_started(_config, _mode), do: {:ok, []}
    end

    defmodule #{inspect(repo)} do
      def __adapter__, do: #{inspect(adapter)}
      def config, do: [otp_app: :ector]
      def start_link(_opts), do: {:error, :no_pool}
    end

    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "legacy_repo_start_failure_#{suffix}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/repo_start_failure.ex", source)
      Code.compile_file(path)

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Ector.Migrate.run(["--data", "--repo", repo_name])
        end

      assert Exception.message(error) =~ "Could not start repo #{inspect(repo)}"
      assert Exception.message(error) =~ ":no_pool"
    end)
  end

  test "data backfill converts relational rows into nodes and implicit edges" do
    suffix = unique_suffix()
    parent_table = "legacy_parents_#{suffix}"
    child_table = "legacy_children_#{suffix}"
    parent_module = Module.concat([Ector.MigrateFixture, "BackfillParent#{suffix}"])
    child_module = Module.concat([Ector.MigrateFixture, "BackfillChild#{suffix}"])

    source = """
    defmodule #{inspect(child_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{child_table}" do
        field(:title, :string)
        belongs_to(:parent, #{inspect(parent_module)}, foreign_key: :parent_id, type: :string)
      end
    end

    defmodule #{inspect(parent_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{parent_table}" do
        field(:name, :string)
        has_many(:children, #{inspect(child_module)}, foreign_key: :parent_id)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/backfill_schemas.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_legacy_tables!(parent_table, child_table)

      on_exit(fn ->
        drop_legacy_tables!(parent_table, child_table)
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()
      assert {1, nil} = repo.insert_all(parent_module, [%{id: "parent-1", name: "Ada"}])

      assert {1, nil} =
               repo.insert_all(child_module, [
                 %{id: "child-1", title: "Notes", parent_id: "parent-1"}
               ])

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])

      parent_label = module_label(parent_module)
      child_label = module_label(child_module)
      nodes = load_nodes_by_label()

      assert map_size(nodes) == 2

      assert %{id: parent_storage_id, properties: parent_properties} =
               Map.fetch!(nodes, parent_label)

      assert %{id: child_storage_id, properties: child_properties} =
               Map.fetch!(nodes, child_label)

      assert_uuid(parent_storage_id)
      assert_uuid(child_storage_id)
      refute parent_storage_id == "parent-1"
      refute child_storage_id == "child-1"
      assert parent_properties["id"] == "parent-1"
      assert parent_properties["name"] == "Ada"
      assert child_properties["id"] == "child-1"
      assert child_properties["title"] == "Notes"
      assert child_properties["parent_id"] == "parent-1"

      assert [[edge_label, source_id, target_id, edge_properties]] =
               Ector.TestRepo.query!("SELECT label, source_id, target_id, properties FROM edges").rows

      assert edge_label == "CHILDREN"
      assert normalize_uuid(source_id) == parent_storage_id
      assert normalize_uuid(target_id) == child_storage_id
      assert decode_properties(edge_properties) == %{}

      recompile_schema_file!(path)

      assert [parent] = repo.all(parent_module)
      assert parent.id == "parent-1"
      assert parent.__id__ == parent_storage_id

      assert [child] = repo.all(child_module)
      assert child.id == "child-1"
      assert child.__id__ == child_storage_id
    end)
  end

  test "data backfill skips edge rows when a legacy parent id is missing" do
    suffix = unique_suffix()
    parent_table = "legacy_missing_edge_parents_#{suffix}"
    child_table = "legacy_missing_edge_children_#{suffix}"
    parent_module = Module.concat([Ector.MigrateFixture, "MissingEdgeParent#{suffix}"])
    child_module = Module.concat([Ector.MigrateFixture, "MissingEdgeChild#{suffix}"])

    source = """
    defmodule #{inspect(parent_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{parent_table}" do
        field(:name, :string)
      end
    end

    defmodule #{inspect(child_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{child_table}" do
        field(:title, :string)
        belongs_to(:parent, #{inspect(parent_module)}, foreign_key: :parent_id, type: :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/missing_edge_schemas.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_legacy_tables!(parent_table, child_table)

      on_exit(fn ->
        drop_legacy_tables!(parent_table, child_table)
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()
      assert {1, nil} = repo.insert_all(parent_module, [%{id: "parent-1", name: "Ada"}])

      assert {1, nil} =
               repo.insert_all(child_module, [
                 %{id: "child-1", title: "Orphan", parent_id: "missing-parent"}
               ])

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])

      assert ["child-1", "parent-1"] =
               load_node_properties()
               |> Enum.map(& &1["id"])
               |> Enum.sort()

      assert Ector.TestRepo.query!("SELECT COUNT(*) FROM edges").rows == [[0]]
    end)
  end

  test "data backfill uses independent workers when concurrent stream checkout is available" do
    suffix = unique_suffix()
    table = "legacy_concurrent_stream_#{suffix}"
    module = Module.concat([Ector.MigrateFixture, "ConcurrentStream#{suffix}"])

    source = """
    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{table}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/concurrent_stream.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_name_table!(table)

      on_exit(fn ->
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{table}")
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()
      previous_config = Application.fetch_env!(:ector, repo)

      try do
        Application.put_env(:ector, repo, Keyword.put(previous_config, :pool_size, 2))
        restart_repo_pool(repo)

        assert {2, nil} =
                 repo.insert_all(module, [
                   %{id: "row-1", name: "One"},
                   %{id: "row-2", name: "Two"}
                 ])

        assert :ok = Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])

        assert ["row-1", "row-2"] =
                 load_node_properties()
                 |> Enum.map(& &1["id"])
                 |> Enum.sort()
      after
        Application.put_env(:ector, repo, previous_config)
        restart_repo_pool(repo)
      end
    end)
  end

  test "concurrent node backfill reports worker insert-count failures" do
    if Ector.TestRepo.sqlite?() do
      suffix = unique_suffix()
      table = "legacy_node_insert_failure_#{suffix}"
      module = Module.concat([Ector.MigrateFixture, "NodeInsertFailure#{suffix}"])

      source = """
      defmodule #{inspect(module)} do
        use Ecto.Schema

        @primary_key {:id, :string, []}
        schema "#{table}" do
          field(:name, :string)
        end
      end
      """

      in_tmp_project(fn ->
        path = write_schema_file!("lib/node_insert_failure.ex", source)
        Code.compile_file(path)

        reset_storage!()
        create_name_table!(table)

        on_exit(fn ->
          Ector.TestRepo.query!("DROP TABLE IF EXISTS #{table}")
          reset_storage!()
        end)

        repo = Ector.TestRepo.repo_module()
        previous_config = Application.fetch_env!(:ector, repo)

        try do
          Application.put_env(:ector, repo, Keyword.put(previous_config, :pool_size, 2))
          restart_repo_pool(repo)

          install_migrator_storage!(repo)
          create_ignore_insert_trigger!("nodes")

          assert {1, nil} = repo.insert_all(module, [%{id: "row-1", name: "One"}])

          previous_trap_exit = Process.flag(:trap_exit, true)

          try do
            error =
              assert_raise Mix.Error, fn ->
                Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])
              end

            assert Exception.message(error) =~ "failed to backfill #{inspect(module)} rows"
            assert Exception.message(error) =~ "Expected to insert 1 nodes rows, inserted 0"
          after
            flush_exit_messages()
            Process.flag(:trap_exit, previous_trap_exit)
          end
        after
          Application.put_env(:ector, repo, previous_config)
          restart_repo_pool(repo)
        end
      end)
    end
  end

  test "concurrent edge backfill reports worker insert-count failures" do
    if Ector.TestRepo.sqlite?() do
      suffix = unique_suffix()
      parent_table = "legacy_edge_failure_parents_#{suffix}"
      child_table = "legacy_edge_failure_children_#{suffix}"
      parent_module = Module.concat([Ector.MigrateFixture, "EdgeFailureParent#{suffix}"])
      child_module = Module.concat([Ector.MigrateFixture, "EdgeFailureChild#{suffix}"])

      source = """
      defmodule #{inspect(parent_module)} do
        use Ecto.Schema

        @primary_key {:id, :string, []}
        schema "#{parent_table}" do
          field(:name, :string)
          has_many(:children, #{inspect(child_module)}, foreign_key: :parent_id)
        end
      end

      defmodule #{inspect(child_module)} do
        use Ecto.Schema

        @primary_key {:id, :string, []}
        schema "#{child_table}" do
          field(:title, :string)
          belongs_to(:parent, #{inspect(parent_module)}, foreign_key: :parent_id, type: :string)
        end
      end
      """

      in_tmp_project(fn ->
        path = write_schema_file!("lib/edge_insert_failure.ex", source)
        Code.compile_file(path)

        reset_storage!()
        create_legacy_tables!(parent_table, child_table)

        on_exit(fn ->
          drop_legacy_tables!(parent_table, child_table)
          reset_storage!()
        end)

        repo = Ector.TestRepo.repo_module()
        previous_config = Application.fetch_env!(:ector, repo)

        try do
          Application.put_env(:ector, repo, Keyword.put(previous_config, :pool_size, 2))
          restart_repo_pool(repo)

          install_migrator_storage!(repo)
          create_ignore_insert_trigger!("edges")

          assert {1, nil} = repo.insert_all(parent_module, [%{id: "parent-1", name: "Ada"}])

          assert {1, nil} =
                   repo.insert_all(child_module, [
                     %{id: "child-1", title: "Notes", parent_id: "parent-1"}
                   ])

          previous_trap_exit = Process.flag(:trap_exit, true)

          try do
            error =
              assert_raise Mix.Error, fn ->
                Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])
              end

            assert Exception.message(error) =~
                     "failed to backfill #{inspect(parent_module)} -> #{inspect(child_module)} edges"

            assert Exception.message(error) =~ "Expected to insert 1 edges rows, inserted 0"
          after
            flush_exit_messages()
            Process.flag(:trap_exit, previous_trap_exit)
          end
        after
          Application.put_env(:ector, repo, previous_config)
          restart_repo_pool(repo)
        end
      end)
    end
  end

  test "data backfill normalizes JSON-compatible scalar and nested values" do
    suffix = unique_suffix()
    table = "legacy_payloads_#{suffix}"
    module = Module.concat([Ector.MigrateFixture, "Payload#{suffix}"])
    type_module = Module.concat([Ector.MigrateFixture, "PayloadType#{suffix}"])
    no_load_type_module = Module.concat([Ector.MigrateFixture, "NoLoadPayloadType#{suffix}"])

    source = """
    defmodule #{inspect(no_load_type_module)} do
      def type, do: :string
      def cast(value), do: {:ok, value}
      def dump(_value), do: {:ok, "no-load"}
    end

    defmodule #{inspect(type_module)} do
      @behaviour Ecto.Type

      def type, do: :string
      def cast(value), do: {:ok, value}
      def dump(_value), do: {:ok, "typed-payload"}
      def embed_as(_format), do: :self
      def equal?(left, right), do: left == right

      def load(_value) do
        {:ok,
         %{
           decimal: Decimal.new("42.50"),
           date: ~D[2026-06-13],
           time: ~T[14:15:16],
           naive: ~N[2026-06-13 14:15:16],
           utc: ~U[2026-06-13 14:15:16Z],
           nested: [%{decimal: Decimal.new("7.25")}, [~D[2026-06-14]]]
         }}
      end
    end

    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{table}" do
        field(:amount, :decimal)
        field(:bad_amount, :decimal)
        field(:starts_on, :date)
        field(:starts_at, :time)
        field(:seen_at, :naive_datetime)
        field(:published_at, :utc_datetime)
        field(:payload, :map)
        field(:typed_payload, #{inspect(type_module)})
        field(:unloaded_payload, #{inspect(no_load_type_module)})
        field(:raw_payload, :map)
        field(:labels, {:array, :string})
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/payload.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_payload_table!(table)

      on_exit(fn ->
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{table}")
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()

      assert {1, nil} =
               repo.insert_all(module, [
                 %{
                   id: "payload-1",
                   amount: Decimal.new("123.45"),
                   starts_on: ~D[2026-06-12],
                   starts_at: ~T[13:14:15],
                   seen_at: ~N[2026-06-12 13:14:15],
                   published_at: ~U[2026-06-12 13:14:15Z],
                   payload: %{
                     "nested" => [%{"name" => "inner"}, [1, true, nil]],
                     "map" => %{"count" => 2}
                   },
                   typed_payload: %{},
                   unloaded_payload: %{}
                 }
               ])

      update_payload_labels!(table, "payload-1", "alpha,beta")

      if Ector.TestRepo.sqlite?() do
        Ector.TestRepo.query!(
          "UPDATE #{table} SET bad_amount = 'not-decimal', raw_payload = 'not-json' WHERE id = ?",
          ["payload-1"]
        )
      end

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])

      properties = only_node_properties()

      assert %{
               "id" => "payload-1",
               "amount" => "123.45",
               "bad_amount" => bad_amount,
               "starts_on" => "2026-06-12",
               "starts_at" => "13:14:15",
               "seen_at" => "2026-06-12T13:14:15",
               "published_at" => "2026-06-12T13:14:15Z",
               "payload" => %{
                 "nested" => [%{"name" => "inner"}, [1, true, nil]],
                 "map" => %{"count" => 2}
               },
               "typed_payload" => %{
                 "decimal" => "42.50",
                 "date" => "2026-06-13",
                 "time" => "14:15:16",
                 "naive" => "2026-06-13T14:15:16",
                 "utc" => "2026-06-13T14:15:16Z",
                 "nested" => [%{"decimal" => "7.25"}, ["2026-06-14"]]
               },
               "labels" => "alpha,beta"
             } = properties

      assert properties["unloaded_payload"] == "no-load"

      if Ector.TestRepo.sqlite?() do
        assert bad_amount == "not-decimal"
        assert properties["raw_payload"] == "not-json"
      else
        assert bad_amount == nil
      end
    end)
  end

  test "single-connection fallback ingests chunks synchronously without buffering the table" do
    suffix = unique_suffix()
    table = "legacy_single_connection_#{suffix}"
    module = Module.concat([Ector.MigrateFixture, "SingleConnection#{suffix}"])

    source = """
    defmodule #{inspect(module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{table}" do
        field(:name, :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/single_connection.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_name_table!(table)

      on_exit(fn ->
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{table}")
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()
      previous_config = Application.fetch_env!(:ector, repo)

      try do
        Application.put_env(:ector, repo, Keyword.put(previous_config, :pool_size, 1))

        assert {3, nil} =
                 repo.insert_all(module, [
                   %{id: "row-1", name: "One"},
                   %{id: "row-2", name: "Two"},
                   %{id: "row-3", name: "Three"}
                 ])

        assert :ok = Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])

        assert ["row-1", "row-2", "row-3"] =
                 load_node_properties()
                 |> Enum.map(& &1["id"])
                 |> Enum.sort()
      after
        Application.put_env(:ector, repo, previous_config)
        restart_repo_pool(repo)
      end
    end)
  end

  test "data backfill ignores missing incoming targets and unsupported associations" do
    suffix = unique_suffix()
    child_table = "legacy_missing_target_children_#{suffix}"
    article_table = "legacy_articles_#{suffix}"
    tag_table = "legacy_tags_#{suffix}"
    join_table = "legacy_article_tags_#{suffix}"
    external_parent = Module.concat([Ector.MigrateFixture, "ExternalParent#{suffix}"])
    child_module = Module.concat([Ector.MigrateFixture, "MissingTargetChild#{suffix}"])
    article_module = Module.concat([Ector.MigrateFixture, "Article#{suffix}"])
    tag_module = Module.concat([Ector.MigrateFixture, "Tag#{suffix}"])

    Code.compile_string("""
    defmodule #{inspect(external_parent)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "external_parents_#{suffix}" do
        field(:name, :string)
      end
    end
    """)

    source = """
    defmodule #{inspect(tag_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{tag_table}" do
        field(:name, :string)
      end
    end

    defmodule #{inspect(article_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{article_table}" do
        field(:title, :string)
        many_to_many(:tags, #{inspect(tag_module)}, join_through: "#{join_table}")
      end
    end

    defmodule #{inspect(child_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{child_table}" do
        field(:title, :string)
        belongs_to(:parent, #{inspect(external_parent)}, foreign_key: :parent_id, type: :string)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/ignored_associations.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_name_table!(tag_table)
      Ector.TestRepo.query!("CREATE TABLE #{article_table} (id text PRIMARY KEY, title text)")

      Ector.TestRepo.query!(
        "CREATE TABLE #{child_table} (id text PRIMARY KEY, title text, parent_id text)"
      )

      on_exit(fn ->
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{child_table}")
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{article_table}")
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{tag_table}")
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()
      assert {1, nil} = repo.insert_all(tag_module, [%{id: "tag-1", name: "Migration"}])
      assert {1, nil} = repo.insert_all(article_module, [%{id: "article-1", title: "Notes"}])

      assert {1, nil} =
               repo.insert_all(child_module, [
                 %{id: "child-1", title: "External", parent_id: "parent-1"}
               ])

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--data", "--chunk-size", "1"])

      assert ["article-1", "child-1", "tag-1"] =
               load_node_properties()
               |> Enum.map(& &1["id"])
               |> Enum.sort()

      assert Ector.TestRepo.query!("SELECT COUNT(*) FROM edges").rows == [[0]]
    end)
  end

  test "data backfill rejects schemas without a single primary key" do
    suffix = unique_suffix()

    invalid_schemas = [
      {
        """
        defmodule #{inspect(Module.concat([Ector.MigrateFixture, "NoPrimaryKey#{suffix}"]))} do
          use Ecto.Schema

          @primary_key false
          schema "legacy_no_primary_key_#{suffix}" do
            field(:name, :string)
          end
        end
        """,
        "has no primary key"
      },
      {
        """
        defmodule #{inspect(Module.concat([Ector.MigrateFixture, "CompositePrimaryKey#{suffix}"]))} do
          use Ecto.Schema

          @primary_key false
          schema "legacy_composite_primary_key_#{suffix}" do
            field(:left_id, :string, primary_key: true)
            field(:right_id, :string, primary_key: true)
          end
        end
        """,
        "composite primary key"
      }
    ]

    Enum.each(invalid_schemas, fn {source, message} ->
      in_tmp_project(fn ->
        path = write_schema_file!("lib/invalid_schema.ex", source)
        Code.compile_file(path)

        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Ector.Migrate.run(["--data"])
          end

        assert Exception.message(error) =~ message
      end)
    end)
  end

  test "data backfill skips associations whose target schema was not migrated" do
    suffix = unique_suffix()
    parent_table = "legacy_orphan_parents_#{suffix}"
    child_module = Module.concat([Ector.MigrateFixture, "ExternalChild#{suffix}"])
    parent_module = Module.concat([Ector.MigrateFixture, "OrphanParent#{suffix}"])

    Code.compile_string("""
    defmodule #{inspect(child_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "external_children_#{suffix}" do
        field(:parent_id, :string)
      end
    end
    """)

    source = """
    defmodule #{inspect(parent_module)} do
      use Ecto.Schema

      @primary_key {:id, :string, []}
      schema "#{parent_table}" do
        field(:name, :string)
        has_many(:external_children, #{inspect(child_module)}, foreign_key: :parent_id)
      end
    end
    """

    in_tmp_project(fn ->
      path = write_schema_file!("lib/orphan_parent.ex", source)
      Code.compile_file(path)

      reset_storage!()
      create_name_table!(parent_table)

      on_exit(fn ->
        Ector.TestRepo.query!("DROP TABLE IF EXISTS #{parent_table}")
        reset_storage!()
      end)

      repo = Ector.TestRepo.repo_module()
      assert {1, nil} = repo.insert_all(parent_module, [%{id: "parent-1", name: "Lonely"}])

      assert :ok = Mix.Tasks.Ector.Migrate.run(["--data"])

      assert [%{"id" => "parent-1", "name" => "Lonely"}] = load_node_properties()
      assert Ector.TestRepo.query!("SELECT COUNT(*) FROM edges").rows == [[0]]
    end)
  end

  test "storage migration down removes Ector tables" do
    version = 20_260_612_900_000 + unique_suffix()
    repo = Ector.TestRepo.repo_module()

    reset_storage!()

    on_exit(fn -> reset_storage!() end)

    assert :ok =
             Ecto.Migrator.up(repo, version, Mix.Tasks.Ector.Migrate.StorageMigration, log: false)

    assert Ector.TestRepo.table_exists?("nodes")
    assert Ector.TestRepo.table_exists?("edges")

    assert :ok =
             Ecto.Migrator.down(repo, version, Mix.Tasks.Ector.Migrate.StorageMigration,
               log: false
             )

    refute Ector.TestRepo.table_exists?("nodes")
    refute Ector.TestRepo.table_exists?("edges")
  end

  defp restore_app_env(app, key, :__ector_migrate_unset__), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp unique_suffix do
    System.unique_integer([:positive])
  end

  defp in_tmp_project(callback) when is_function(callback, 0) do
    root = Path.join(System.tmp_dir!(), "ector_migrate_test_#{unique_suffix()}")
    File.mkdir_p!(Path.join(root, "lib"))

    cwd = File.cwd!()

    try do
      File.cd!(root, callback)
    after
      File.cd!(cwd)
      File.rm_rf!(root)
    end
  end

  defp write_schema_file!(path, source) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end

  defp recompile_schema_file!(path) do
    previous_options = Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_file(path)
    after
      Code.compiler_options(previous_options)
    end
  end

  defp create_legacy_tables!(parent_table, child_table) do
    Ector.TestRepo.query!(
      "CREATE TABLE #{parent_table} (id text PRIMARY KEY, name text NOT NULL)"
    )

    Ector.TestRepo.query!(
      "CREATE TABLE #{child_table} (id text PRIMARY KEY, title text NOT NULL, parent_id text NOT NULL)"
    )
  end

  defp create_name_table!(table) do
    Ector.TestRepo.query!("CREATE TABLE #{table} (id text PRIMARY KEY, name text NOT NULL)")
  end

  defp create_payload_table!(table) do
    statement =
      if Ector.TestRepo.postgres?() do
        """
        CREATE TABLE #{table} (
          id text PRIMARY KEY,
          amount numeric,
          bad_amount text,
          starts_on date,
          starts_at time,
          seen_at timestamp,
          published_at timestamptz,
          payload jsonb,
          typed_payload text,
          unloaded_payload text,
          raw_payload text,
          labels text
        )
        """
      else
        """
        CREATE TABLE #{table} (
          id text PRIMARY KEY,
          amount numeric,
          bad_amount text,
          starts_on text,
          starts_at text,
          seen_at text,
          published_at text,
          payload text,
          typed_payload text,
          unloaded_payload text,
          raw_payload text,
          labels text
        )
        """
      end

    Ector.TestRepo.query!(statement)
  end

  defp update_payload_labels!(table, id, labels) do
    if Ector.TestRepo.postgres?() do
      Ector.TestRepo.query!("UPDATE #{table} SET labels = $1 WHERE id = $2", [labels, id])
    else
      Ector.TestRepo.query!("UPDATE #{table} SET labels = ? WHERE id = ?", [labels, id])
    end
  end

  defp drop_legacy_tables!(parent_table, child_table) do
    Ector.TestRepo.query!("DROP TABLE IF EXISTS #{child_table}")
    Ector.TestRepo.query!("DROP TABLE IF EXISTS #{parent_table}")
  end

  defp reset_storage! do
    Ector.TestRepo.drop_core_tables!()
  end

  defp install_migrator_storage!(repo) do
    Ecto.Migrator.up(repo, 20_260_612_000_001, Mix.Tasks.Ector.Migrate.StorageMigration,
      log: false
    )
  end

  defp create_ignore_insert_trigger!(table) when table in ["nodes", "edges"] do
    Ector.TestRepo.query!("""
    CREATE TRIGGER ignore_#{table}_insert
    BEFORE INSERT ON #{table}
    BEGIN
      SELECT RAISE(IGNORE);
    END
    """)
  end

  defp restart_repo_pool(repo) do
    if pid = Process.whereis(repo) do
      Supervisor.stop(pid)
    end

    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end

  defp load_nodes_by_label do
    Ector.TestRepo.query!("SELECT id, label, properties FROM nodes").rows
    |> Map.new(fn [id, label, properties] ->
      {label, %{id: normalize_uuid(id), properties: decode_properties(properties)}}
    end)
  end

  defp load_node_properties do
    Ector.TestRepo.query!("SELECT properties FROM nodes").rows
    |> Enum.map(fn [properties] -> decode_properties(properties) end)
  end

  defp only_node_properties do
    assert [properties] = load_node_properties()
    properties
  end

  defp decode_properties(value) when is_binary(value), do: JSON.decode!(value)
  defp decode_properties(value) when is_map(value), do: value

  defp normalize_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp normalize_uuid(value), do: value

  defp assert_uuid(value) do
    assert {:ok, ^value} = Ecto.UUID.cast(value)
  end

  defp module_label(module) do
    module
    |> Module.split()
    |> List.last()
  end
end
