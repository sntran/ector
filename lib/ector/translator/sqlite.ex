defmodule Ector.Translator.SQLite do
  @moduledoc """
  Builds SQLite `json_set` expressions for Ector bulk updates.
  """

  @behaviour Ector.Translator

  @doc false
  @impl true
  @spec json_set(Macro.t(), [String.t()], Ector.Translator.json_value_payload()) :: Macro.t()
  def json_set(acc, path, %{encoded: encoded_value}) do
    json_path = "$." <> Enum.join(path, ".")

    append_json_set(acc, json_path, encoded_value)
  end

  defp append_json_set(%Ecto.Query.DynamicExpr{} = acc, json_path, encoded_value) do
    %Ecto.Query.DynamicExpr{
      binding: acc.binding,
      file: __ENV__.file,
      line: __ENV__.line,
      fun: fn query ->
        {ast, params, subqueries, aliases} = acc.fun.(query)
        path_param_index = length(params)

        {
          append_json_set_expr(ast, path_param_index),
          params ++ [{json_path, :any}, {encoded_value, :any}],
          subqueries,
          aliases
        }
      end
    }
  end

  defp append_json_set(ast, json_path, encoded_value) do
    %Ecto.Query.DynamicExpr{
      binding: [{:row, [], nil}],
      file: __ENV__.file,
      line: __ENV__.line,
      fun: fn _query ->
        {append_json_set_expr(ast, 0), [{json_path, :any}, {encoded_value, :any}], [], %{}}
      end
    }
  end

  defp append_json_set_expr({:fragment, meta, [{:raw, "json_set("} | rest]}, path_index) do
    {{:raw, ")"}, body} = List.pop_at(rest, -1)

    {:fragment, meta, [{:raw, "json_set("} | body] ++ json_set_tail(path_index) ++ [raw: ")"]}
  end

  defp append_json_set_expr(ast, path_index) do
    append_json_set_expr(ast, path_index, :wrap)
  end

  defp append_json_set_expr(ast, path_index, :wrap) do
    {:fragment, [], [raw: "json_set(", expr: ast] ++ json_set_tail(path_index) ++ [raw: ")"]}
  end

  defp json_set_tail(path_index) do
    value_index = path_index + 1

    [
      raw: ", ",
      expr: {:^, [], [path_index]},
      raw: ", json(",
      expr: {:^, [], [value_index]},
      raw: ")"
    ]
  end
end
