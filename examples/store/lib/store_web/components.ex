defmodule StoreWeb.Components do
  @moduledoc false

  def money(cents) when is_integer(cents) do
    dollars = cents / 100

    :erlang.float_to_binary(dollars, decimals: 2)
    |> then(&"$#{&1}")
  end

  def money(_cents), do: "$0.00"

  def short(text, max \\ 120)
  def short(nil, _max), do: ""

  def short(text, max) when is_binary(text) and byte_size(text) > max do
    text
    |> String.slice(0, max)
    |> String.trim()
    |> then(&"#{&1}...")
  end

  def short(text, _max) when is_binary(text), do: text
end
