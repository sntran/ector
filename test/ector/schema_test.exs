defmodule Ector.SchemaTest do
  use ExUnit.Case, async: true

  defmodule User do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  test "ector_schema?/1 detects Ector modules structs and non-schema values" do
    assert Ector.Schema.ector_schema?(User)
    assert Ector.Schema.ector_schema?(%User{})

    refute Ector.Schema.ector_schema?("string")
    refute Ector.Schema.ector_schema?(123)
  end
end
