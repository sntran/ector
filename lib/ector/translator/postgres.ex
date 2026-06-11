defmodule Ector.Translator.Postgres do
  @moduledoc """
  Builds PostgreSQL `jsonb_set/4` expressions for Ector bulk updates.
  """

  @behaviour Ector.Translator

  import Ecto.Query

  @doc false
  @impl true
  @spec json_set(Macro.t(), [String.t()], Ector.Translator.json_value_payload()) :: Macro.t()
  def json_set(acc, path, %{raw: scalar_value}) when is_binary(scalar_value) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, to_jsonb(?), true)",
        ^acc,
        type(^path, {:array, :string}),
        type(^scalar_value, :string)
      )
    )
  end

  def json_set(acc, path, %{raw: scalar_value}) when is_integer(scalar_value) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, to_jsonb(?), true)",
        ^acc,
        type(^path, {:array, :string}),
        type(^scalar_value, :integer)
      )
    )
  end

  def json_set(acc, path, %{raw: scalar_value}) when is_float(scalar_value) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, to_jsonb(?), true)",
        ^acc,
        type(^path, {:array, :string}),
        type(^scalar_value, :float)
      )
    )
  end

  def json_set(acc, path, %{raw: scalar_value}) when is_boolean(scalar_value) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, to_jsonb(?), true)",
        ^acc,
        type(^path, {:array, :string}),
        type(^scalar_value, :boolean)
      )
    )
  end

  def json_set(acc, path, %{raw: nil}) do
    dynamic(
      [row],
      fragment("jsonb_set(?, ?, 'null'::jsonb, true)", ^acc, type(^path, {:array, :string}))
    )
  end

  def json_set(acc, path, %{encoded: encoded_value, raw: compound_value})
      when is_map(compound_value) or is_list(compound_value) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, (?::text)::jsonb, true)",
        ^acc,
        type(^path, {:array, :string}),
        ^encoded_value
      )
    )
  end

  def json_set(acc, path, %{encoded: encoded_value}) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, ?::jsonb, true)",
        ^acc,
        type(^path, {:array, :string}),
        ^encoded_value
      )
    )
  end

  @doc false
  @impl true
  @spec json_inc(Macro.t(), [String.t()], number()) :: Macro.t()
  def json_inc(acc, path, amount) when is_integer(amount) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, to_jsonb(COALESCE((? #>> ?)::integer, 0) + ?), true)",
        ^acc,
        type(^path, {:array, :string}),
        ^acc,
        type(^path, {:array, :string}),
        type(^amount, :integer)
      )
    )
  end

  def json_inc(acc, path, amount) when is_float(amount) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, to_jsonb(COALESCE((? #>> ?)::double precision, 0) + ?), true)",
        ^acc,
        type(^path, {:array, :string}),
        ^acc,
        type(^path, {:array, :string}),
        type(^amount, :float)
      )
    )
  end

  @doc false
  @impl true
  @spec json_push(Macro.t(), [String.t()], Ector.Translator.json_value_payload()) :: Macro.t()
  def json_push(acc, path, %{encoded: encoded_value}) do
    dynamic(
      [row],
      fragment(
        "jsonb_set(?, ?, COALESCE(? #> ?, '[]'::jsonb) || jsonb_build_array((?::text)::jsonb), true)",
        ^acc,
        type(^path, {:array, :string}),
        ^acc,
        type(^path, {:array, :string}),
        ^encoded_value
      )
    )
  end
end
