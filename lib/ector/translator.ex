defmodule Ector.Translator do
  @moduledoc """
  Dispatches adapter-specific JSON mutation builders for bulk Ector updates.

  `Ector.Repo.update_all/3` uses this module to translate domain-field `set`,
  `inc`, and `push` updates into a single `properties` expression tailored to
  the active adapter. The resulting expression is still executed by Ecto,
  keeping planning and SQL generation inside the adapter boundary.
  """

  import Ecto.Query

  @typedoc "Bulk update operators Ector can route through the JSON properties column."
  @type update_operator :: :set | :inc | :push

  @typedoc "Field/value pairs destined for the shared `properties` JSON column."
  @type field_updates :: keyword(term())

  @typedoc "Ecto-style bulk update operators for Ector domain fields."
  @type update_operations :: keyword(field_updates())

  @type json_value_payload :: %{encoded: String.t(), raw: term()}

  @callback json_set(Macro.t(), [String.t()], json_value_payload()) :: Macro.t()
  @callback json_inc(Macro.t(), [String.t()], number()) :: Macro.t()
  @callback json_push(Macro.t(), [String.t()], json_value_payload()) :: Macro.t()

  @update_operators [:set, :inc, :push]

  @doc false
  @spec properties_update_expression(module(), update_operations() | field_updates()) :: Macro.t()
  def properties_update_expression(repo, updates)
      when is_atom(repo) and is_list(updates) do
    adapter = module_for(repo)

    reduce_json_updates(adapter, normalized_updates(updates))
  end

  defp reduce_json_updates(adapter, normalized_updates)
       when is_atom(adapter) and is_list(normalized_updates) do
    Enum.reduce(
      normalized_updates,
      dynamic([row], field(row, :properties)),
      fn
        {:set, field_name, payload}, acc ->
          adapter.json_set(acc, [field_name], payload)

        {:inc, field_name, amount}, acc ->
          adapter.json_inc(acc, [field_name], amount)

        {:push, field_name, payload}, acc ->
          adapter.json_push(acc, [field_name], payload)
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

  @spec normalized_updates(update_operations() | field_updates()) ::
          [{update_operator(), String.t(), json_value_payload() | number()}]
  defp normalized_updates(updates) when is_list(updates) do
    if operator_updates?(updates) do
      Enum.flat_map(updates, fn {operator, field_updates} ->
        normalize_operator_updates(operator, field_updates)
      end)
    else
      normalize_operator_updates(:set, updates)
    end
  end

  defp operator_updates?(updates) when is_list(updates) do
    updates != [] and
      Enum.all?(updates, fn
        {operator, field_updates} when operator in @update_operators and is_list(field_updates) ->
          true

        _other ->
          false
      end)
  end

  defp normalize_operator_updates(operator, field_updates)
       when operator in [:set, :push] and is_list(field_updates) do
    Enum.map(field_updates, fn {field_name, value} ->
      {operator, normalize_field_name(field_name), json_payload(value)}
    end)
  end

  defp normalize_operator_updates(:inc, field_updates) when is_list(field_updates) do
    Enum.map(field_updates, fn
      {field_name, value} when is_number(value) ->
        {:inc, normalize_field_name(field_name), value}
    end)
  end

  defp normalize_field_name(field_name) when is_atom(field_name), do: Atom.to_string(field_name)
  defp normalize_field_name(field_name) when is_binary(field_name), do: field_name

  defp json_payload(value) do
    %{encoded: encode_json!(value), raw: value}
  end
end
