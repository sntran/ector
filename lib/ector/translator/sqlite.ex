defmodule Ector.Translator.SQLite do
  @moduledoc """
  Builds SQLite `json_set/3` expressions for Ector bulk updates.
  """

  @behaviour Ector.Translator

  import Ecto.Query

  @doc false
  @impl true
  @spec json_set(Macro.t(), [String.t()], Ector.Translator.json_value_payload()) :: Macro.t()
  def json_set(acc, path, %{encoded: encoded_value}) do
    json_path = "$." <> Enum.join(path, ".")

    dynamic([row], fragment("json_set(?, ?, json(?))", ^acc, ^json_path, ^encoded_value))
  end
end
