defmodule Store.Storage do
  @moduledoc """
  Batch storage helpers for the storefront example.

  These helpers write directly to Ector's physical storage tables for seed and
  fixture throughput. Domain reads still go through `Ector.join/3` and
  `Ector.select/3`.
  """

  alias Store.Repo

  @type node_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:label) => String.t(),
          required(:properties) => map()
        }

  @type edge_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:label) => String.t(),
          required(:source_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t(),
          required(:properties) => map()
        }

  @doc "Generates the UUIDv7 tokens used by the storage topology."
  @spec uuidv7() :: Ecto.UUID.t()
  def uuidv7 do
    Ecto.UUID.generate(version: 7, precision: :monotonic)
  end

  @doc "Builds a row for the shared `nodes` table."
  @spec node_row(module(), map(), Ecto.UUID.t()) :: node_row()
  def node_row(module, properties, storage_id \\ uuidv7())
      when is_atom(module) and is_map(properties) and is_binary(storage_id) do
    %{id: storage_id, label: module.__ector_label__(), properties: stringify_keys(properties)}
  end

  @doc "Builds a row for the shared `edges` table."
  @spec edge_row(String.t(), Ecto.UUID.t(), Ecto.UUID.t(), map(), Ecto.UUID.t()) :: edge_row()
  def edge_row(label, source_id, target_id, properties \\ %{}, storage_id \\ uuidv7())
      when is_binary(label) and is_binary(source_id) and is_binary(target_id) and
             is_map(properties) and is_binary(storage_id) do
    %{
      id: storage_id,
      label: label,
      source_id: source_id,
      target_id: target_id,
      properties: stringify_keys(properties)
    }
  end

  @doc "Returns the physical edge label for a schema association."
  @spec edge_label!(module(), atom()) :: String.t()
  def edge_label!(module, association_name) when is_atom(module) and is_atom(association_name) do
    association =
      Enum.find(module.__ector_associations__(), &(&1.name == association_name)) ||
        raise ArgumentError,
              "unknown Ector association #{inspect(association_name)} for #{inspect(module)}"

    case association do
      %{opts: %{through: through}} when is_atom(through) ->
        through |> Atom.to_string() |> String.upcase()

      %{opts: %{through: through}} when is_binary(through) ->
        through |> Macro.underscore() |> String.upcase()

      %{name: name} ->
        name |> Atom.to_string() |> String.upcase()
    end
  end

  @doc "Inserts node rows in chunks sized for SQLite's parameter limit."
  @spec insert_nodes!([node_row()]) :: non_neg_integer()
  def insert_nodes!(rows) when is_list(rows) do
    insert_storage_rows!(Ector.Node, rows, 250)
  end

  @doc "Inserts edge rows in chunks sized for SQLite's parameter limit."
  @spec insert_edges!([edge_row()]) :: non_neg_integer()
  def insert_edges!(rows) when is_list(rows) do
    insert_storage_rows!(Ector.Edge, rows, 150)
  end

  @doc "Deletes all storefront graph data without dropping the schema."
  @spec delete_all!() :: :ok
  def delete_all! do
    Repo.delete_all(Ector.Edge)
    Repo.delete_all(Ector.Node)
    :ok
  end

  defp insert_storage_rows!(schema, rows, chunk_size) do
    rows
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(0, fn chunk, count ->
      {inserted, _result} = Repo.insert_all(schema_source(schema), encode_rows(chunk), [])
      count + inserted
    end)
  end

  defp schema_source(schema) do
    if sqlite?(), do: schema.__schema__(:source), else: schema
  end

  defp encode_rows(rows) do
    if sqlite?() do
      Enum.map(
        rows,
        &Map.update!(&1, :properties, fn value -> Ector.Translator.encode_json!(value) end)
      )
    else
      rows
    end
  end

  defp sqlite? do
    Repo.__adapter__() == Ecto.Adapters.SQLite3
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
