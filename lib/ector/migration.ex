defmodule Ector.Migration do
  @moduledoc """
  Drop-in replacement for `Ecto.Migration` for Ector-backed storage.

  `use Ector.Migration` keeps the familiar migration DSL, but swaps in helpers
  that bootstrap Ector's shared `nodes` and `edges` tables and build indexes
  that understand Ector schema modules.

  When `index/3` receives an Ector node or edge module, it rewrites schema
  fields into JSON property expressions and automatically scopes the index to
  the schema label. That keeps partial indexes selective even though many
  logical schemas live in the same physical table.

  ## Example

      defmodule MyApp.Repo.Migrations.InstallEctor do
        use Ector.Migration

        def change do
          up()

          create index(MyApp.User, [:email], unique: true)
          create index(MyApp.HasCart, [:source_id, :target_id])
        end
      end
  """

  @doc """
  Imports `Ecto.Migration` plus Ector's storage-aware migration helpers.
  """
  defmacro __using__(opts \\ []) do
    quote bind_quoted: [opts: opts] do
      use Ecto.Migration, opts

      import Ecto.Migration, except: [index: 2, index: 3]
      import Ector.Migration, only: [index: 2, index: 3, up: 0, up: 1, down: 0, down: 1]
    end
  end

  @doc """
  Creates Ector's shared `nodes` and `edges` storage tables.

  The generated migration also installs the default label and routing indexes.
  On PostgreSQL, it adds a `GIN` index on `nodes.properties` so JSONB containment
  queries stay fast without exposing PostgreSQL-specific SQL as part of the
  public API.

  ## Examples

      def change do
        up()
      end

      def up do
        Ector.Migration.up(prefix: "tenant_alpha")
      end
  """
  defmacro up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix)
    gin_sql = postgres_gin_index_sql(prefix)

    quote bind_quoted: [prefix: prefix, gin_sql: gin_sql] do
      create table(:nodes, primary_key: false, prefix: prefix) do
        add(:id, :uuid, primary_key: true)
        add(:label, :string, null: false)
        add(:properties, :map, default: "{}", null: false)
      end

      create table(:edges, primary_key: false, prefix: prefix) do
        add(:id, :uuid, primary_key: true)
        add(:label, :string, null: false)

        add(:source_id, references(:nodes, type: :uuid, on_delete: :delete_all, prefix: prefix),
          null: false
        )

        add(:target_id, references(:nodes, type: :uuid, on_delete: :delete_all, prefix: prefix),
          null: false
        )

        add(:properties, :map, default: "{}", null: false)
      end

      create(index(:nodes, [:label], prefix: prefix))
      create(index(:edges, [:source_id], prefix: prefix))
      create(index(:edges, [:target_id], prefix: prefix))
      create(index(:edges, [:source_id, :label], prefix: prefix))

      if repo().__adapter__() == Ecto.Adapters.Postgres do
        execute(fn ->
          repo().query!(gin_sql)
        end)
      end
    end
  end

  @doc """
  Removes Ector's shared `edges` and `nodes` tables.

  ## Examples

      def change do
        down()
      end

      def down do
        Ector.Migration.down(prefix: "tenant_alpha")
      end
  """
  defmacro down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix)

    quote bind_quoted: [prefix: prefix] do
      drop_if_exists(table(:edges, prefix: prefix))
      drop_if_exists(table(:nodes, prefix: prefix))
    end
  end

  @doc """
  Builds an index definition for a raw table or an Ector schema module.

  When `target` is an Ector node or edge schema, business fields are rewritten
  into JSON property expressions and the resulting index is constrained to that
  logical label. Routing columns such as `:id`, `:__id__`, `:label`,
  `:source_id`, and `:target_id` stay mapped to their native storage columns.

  This lets callers write indexes in terms of schema fields while still getting
  adapter-friendly partial indexes over the shared storage tables.

  ## Examples

      create index(MyApp.User, [:email], unique: true)
      create index(MyApp.HasCart, [:source_id, :target_id])
      create index(MyApp.User, [desc: "lower(email)"], where: "verified = TRUE")
  """
  defmacro index(target, columns, opts \\ []) do
    expanded_target = Macro.expand(target, __CALLER__)

    case smart_index_target(expanded_target) do
      {:table, table} ->
        table = validate_table_target(table)
        columns = validate_index_columns(columns)
        opts = validate_index_opts(opts)

        quote bind_quoted: [table: table, columns: columns, opts: opts] do
          require Ecto.Migration
          Ecto.Migration.index(table, columns, opts)
        end

      {:schema, module} ->
        label = module.__ector_label__()
        table = module.__ector_table__() |> validate_table_target()
        columns = validate_index_columns(columns)
        opts = validate_index_opts(opts)

        merged_opts =
          Keyword.put(opts, :where, merge_label_constraint(label, Keyword.get(opts, :where)))

        quote bind_quoted: [
                table: table,
                columns: columns,
                merged_opts: merged_opts
              ] do
          require Ecto.Migration

          rewritten_columns =
            Ector.Migration.__rewrite_index_columns__(
              columns,
              Ector.Migration.__repo_adapter__()
            )

          Ecto.Migration.index(table, rewritten_columns, merged_opts)
        end
    end
  end

  @doc false
  @spec __repo_adapter__() :: module()
  def __repo_adapter__ do
    Ecto.Migration.repo().__adapter__()
  rescue
    _exception -> Ecto.Adapters.Postgres
  end

  @doc false
  @spec __rewrite_index_columns__([term()], module()) :: [term()]
  def __rewrite_index_columns__(columns, adapter) when is_list(columns) and is_atom(adapter) do
    Enum.map(columns, &rewrite_index_column(&1, adapter))
  end

  defp postgres_gin_index_sql(prefix) do
    "CREATE INDEX IF NOT EXISTS nodes_properties_gin ON #{qualified_table(prefix, "nodes")} USING GIN (properties)"
  end

  defp smart_index_target(target) when is_binary(target), do: {:table, target}

  defp smart_index_target(target) when is_atom(target) do
    cond do
      Code.ensure_loaded?(target) and function_exported?(target, :__ector_kind__, 0) ->
        {:schema, target}

      true ->
        {:table, target}
    end
  end

  defp rewrite_index_column({direction, column}, adapter) when direction in [:asc, :desc] do
    expression = rewrite_index_column(column, adapter)

    case expression do
      column when is_atom(column) -> [{direction, column}]
      expression -> "#{expression} #{String.upcase(to_string(direction))}"
    end
  end

  defp rewrite_index_column(:id, _adapter), do: :id
  defp rewrite_index_column(:label, _adapter), do: :label
  defp rewrite_index_column(:source_id, _adapter), do: :source_id
  defp rewrite_index_column(:target_id, _adapter), do: :target_id
  defp rewrite_index_column(:__id__, _adapter), do: :id

  defp rewrite_index_column(column, Ecto.Adapters.SQLite3) when is_atom(column) do
    "json_extract(properties, '$.#{escape_sql_string(column)}')"
  end

  defp rewrite_index_column(column, _adapter) when is_atom(column),
    do: "(properties->>'#{escape_sql_string(column)}')"

  defp rewrite_index_column(column, _adapter) when is_binary(column), do: column

  defp merge_label_constraint(label, nil), do: "label = '#{escape_sql_string(label)}'"

  defp merge_label_constraint(label, existing_where) do
    existing_where = validate_sql_fragment!(existing_where, "index WHERE clause")
    "(#{existing_where}) AND label = '#{escape_sql_string(label)}'"
  end

  defp qualified_table(nil, table), do: table

  defp qualified_table(prefix, table),
    do: ~s("#{escape_identifier(prefix)}"."#{escape_identifier(table)}")

  defp reject_null_byte!(value, context) do
    if String.contains?(value, <<0>>) do
      raise ArgumentError, "#{context} cannot contain null bytes"
    end

    value
  end

  defp reject_sql_comment_sequence!(value, context) do
    if String.contains?(value, ["--", "/*", "*/"]) do
      raise ArgumentError, "#{context} cannot contain SQL comment sequences"
    end

    value
  end

  defp validate_sql_fragment!(value, context) do
    value
    |> to_string()
    |> reject_null_byte!(context)
    |> reject_sql_comment_sequence!(context)
  end

  defp validate_table_target(table) when is_binary(table),
    do: validate_sql_fragment!(table, "SQL table identifier")

  defp validate_table_target(table), do: table

  defp validate_index_columns(columns), do: Enum.map(columns, &validate_index_column/1)

  defp validate_index_column({direction, column}) when direction in [:asc, :desc],
    do: {direction, validate_index_column(column)}

  defp validate_index_column(column) when is_binary(column),
    do: validate_sql_fragment!(column, "index expression")

  defp validate_index_column(column), do: column

  defp validate_index_opts(opts) do
    case Keyword.fetch(opts, :where) do
      {:ok, where} ->
        Keyword.put(opts, :where, validate_sql_fragment!(where, "index WHERE clause"))

      :error ->
        opts
    end
  end

  defp escape_identifier(value) do
    value
    |> validate_sql_fragment!("SQL identifier")
    |> String.replace("\"", "\"\"")
  end

  defp escape_sql_string(value) do
    value
    |> validate_sql_fragment!("SQL string literal")
    |> String.replace("'", "''")
  end
end
