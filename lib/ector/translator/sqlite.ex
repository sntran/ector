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

    append_json_mutation(
      acc,
      [{json_path, :any}, {encoded_value, :any}],
      &append_json_set_expr/2
    )
  end

  @doc false
  @impl true
  @spec json_inc(Macro.t(), [String.t()], number()) :: Macro.t()
  def json_inc(acc, path, amount) when is_number(amount) do
    json_path = "$." <> Enum.join(path, ".")

    append_json_mutation(
      acc,
      [{json_path, :any}, {amount, :any}],
      &append_json_inc_expr/2
    )
  end

  @doc false
  @impl true
  @spec json_push(Macro.t(), [String.t()], Ector.Translator.json_value_payload()) :: Macro.t()
  def json_push(acc, path, %{encoded: encoded_value}) do
    json_path = "$." <> Enum.join(path, ".")

    append_json_mutation(
      acc,
      [{json_path, :any}, {encoded_value, :any}],
      &append_json_push_expr/2
    )
  end

  defp append_json_mutation(%Ecto.Query.DynamicExpr{} = acc, new_params, expr_builder) do
    %Ecto.Query.DynamicExpr{
      binding: acc.binding,
      file: __ENV__.file,
      line: __ENV__.line,
      fun: fn query ->
        {ast, existing_params, subqueries, aliases} = acc.fun.(query)
        path_param_index = length(existing_params)

        {
          expr_builder.(ast, path_param_index),
          existing_params ++ new_params,
          subqueries,
          aliases
        }
      end
    }
  end

  defp append_json_mutation(ast, params, expr_builder) do
    %Ecto.Query.DynamicExpr{
      binding: [{:row, [], nil}],
      file: __ENV__.file,
      line: __ENV__.line,
      fun: fn _query ->
        {expr_builder.(ast, 0), params, [], %{}}
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

  defp append_json_inc_expr(ast, path_index) do
    amount_index = path_index + 1

    {:fragment, [],
     [
       raw: "json_set(",
       expr: ast,
       raw: ", ",
       expr: param(path_index),
       raw: ", json(CAST((COALESCE(CAST(json_extract(",
       expr: ast,
       raw: ", ",
       expr: param(path_index),
       raw: ") AS NUMERIC), 0) + ",
       expr: param(amount_index),
       raw: ") AS TEXT)))"
     ]}
  end

  defp append_json_push_expr(ast, path_index) do
    value_index = path_index + 1

    {:fragment, [],
     [
       raw: "json_set(",
       expr: ast,
       raw: ", ",
       expr: param(path_index),
       raw: ", json_insert(COALESCE(json_extract(",
       expr: ast,
       raw: ", ",
       expr: param(path_index),
       raw: "), '[]'), '$[#]', json(",
       expr: param(value_index),
       raw: ")))"
     ]}
  end

  defp json_set_tail(path_index) do
    value_index = path_index + 1

    [
      raw: ", ",
      expr: param(path_index),
      raw: ", json(",
      expr: param(value_index),
      raw: ")"
    ]
  end

  defp param(index), do: {:^, [], [index]}
end
