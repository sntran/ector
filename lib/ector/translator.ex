defmodule Ector.Translator do
  @moduledoc """
  Dispatches adapter-specific JSON mutation builders for bulk Ector updates.

  `Ector.Repo.update_all/3` uses this module to translate domain-field `set`
  updates into a single `properties` expression tailored to the active adapter.
  The resulting expression is still executed by Ecto, keeping planning and SQL
  generation inside the adapter boundary.
  """

  import Ecto.Query

  @typedoc "Field/value pairs destined for the shared `properties` JSON column."
  @type set_updates :: keyword(term())
  @type json_value_payload :: %{encoded: String.t(), raw: term()}

  @callback json_set(Macro.t(), [String.t()], json_value_payload()) :: Macro.t()

  @doc false
  @spec properties_update_expression(module(), set_updates()) :: Macro.t()
  def properties_update_expression(repo, set_updates)
      when is_atom(repo) and is_list(set_updates) do
    adapter = module_for(repo)

    reduce_json_set(adapter, normalized_updates(set_updates))
  end

  defp reduce_json_set(adapter, normalized_updates)
       when is_atom(adapter) and is_list(normalized_updates) do
    Enum.reduce(
      normalized_updates,
      dynamic([row], field(row, :properties)),
      fn {field_name, encoded, raw}, acc ->
        adapter.json_set(acc, [field_name], %{encoded: encoded, raw: raw})
      end
    )
  end

  @spec module_for(module()) :: module()
  defp module_for(repo) when is_atom(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> Ector.Translator.Postgres
      Ecto.Adapters.SQLite3 -> Ector.Translator.SQLite
      adapter -> raise ArgumentError, "unsupported Ector adapter: #{inspect(adapter)}"
    end
  end

  @doc false
  @spec encode_json!(term()) :: String.t()
  def encode_json!(value) do
    value
    |> JSON.encode_to_iodata!()
    |> IO.iodata_to_binary()
  end

  @spec normalized_updates(set_updates()) :: [{String.t(), String.t(), term()}]
  defp normalized_updates(set_updates) when is_list(set_updates) do
    Enum.map(set_updates, fn
      {field_name, value} when is_atom(field_name) ->
        {Atom.to_string(field_name), encode_json!(value), value}

      {field_name, value} when is_binary(field_name) ->
        {field_name, encode_json!(value), value}
    end)
  end
end
