defmodule EctorTest do
  use ExUnit.Case, async: true

  doctest Ector

  defmodule FacadeUser do
    use Ector.Node

    schema do
      field(:status, :string)

      has_many(:carts, EctorTest.FacadeCart, through: EctorTest.FacadeHasCart)
    end
  end

  defmodule FacadeCart do
    use Ector.Node

    schema do
      field(:status, :string)
    end
  end

  defmodule FacadeHasCart do
    use Ector.Edge

    schema do
      field(:status, :string)
    end
  end

  test "from/2 builds an Ector storage query for a domain schema" do
    require Ector

    query = Ector.from(user in FacadeUser)

    assert elem(query.from.source, 0) == "nodes"
    assert elem(query.from.source, 1) == FacadeUser
  end

  test "where/3 redirects domain fields to the JSON properties payload" do
    require Ector

    value = "active"

    query =
      Ector.from(user in FacadeUser)
      |> Ector.where([user], user.status == ^value)

    assert {:==, _, [{:json_extract_path, _, [_, ["status"]]}, {:^, [], [0]}]} =
             List.last(query.wheres).expr
  end

  test "facade delegates the remaining query macros" do
    {query, _binding} =
      Code.eval_quoted(
        quote do
          require Ector
          active = "active"

          Ector.from(user in unquote(FacadeUser), limit: 10)
          |> Ector.where([user], user.status == ^active)
          |> Ector.or_where([user], user.status == "pending")
          |> Ector.group_by([user], user.status)
          |> Ector.having([user], user.status == "active")
          |> Ector.or_having([user], user.status == "pending")
          |> Ector.order_by([user], user.status)
          |> Ector.select([user], user.status)
        end,
        [],
        __ENV__
      )

    assert query.select
    assert query.order_bys != []
    assert query.group_bys != []
    assert length(query.wheres) == 3
    assert length(query.havings) == 2

    {dynamic_expr, _binding} =
      Code.eval_quoted(
        quote do
          require Ector
          Ector.dynamic([user], user.status == "active")
        end,
        [],
        __ENV__
      )

    assert %Ecto.Query.DynamicExpr{} = dynamic_expr

    {joined, _binding} =
      Code.eval_quoted(
        quote do
          require Ector

          Ector.from(user in unquote(FacadeUser))
          |> Ector.join(:carts, as: :cart)
        end,
        [],
        __ENV__
      )

    assert length(joined.joins) == 2
    assert joined.aliases.cart == 2
  end

  test "facade default arities delegate to query macros" do
    {query, _binding} =
      Code.eval_quoted(
        quote do
          require Ector

          Ector.from(user in unquote(FacadeUser))
          |> Ector.where(true)
          |> Ector.or_where(false)
          |> Ector.group_by(fragment("1"))
          |> Ector.having(true)
          |> Ector.or_having(false)
          |> Ector.order_by(fragment("1"))
          |> Ector.select(1)
        end,
        [],
        __ENV__
      )

    assert query.select.expr == 1
    assert length(query.wheres) == 2
    assert length(query.havings) == 1

    {dynamic_expr, _binding} =
      Code.eval_quoted(
        quote do
          require Ector
          Ector.dynamic(true)
        end,
        [],
        __ENV__
      )

    assert %Ecto.Query.DynamicExpr{} = dynamic_expr

    assert_raise ArgumentError, ~r/require an `as:` alias/, fn ->
      Code.eval_quoted(
        quote do
          require Ector

          Ector.from(user in unquote(FacadeUser))
          |> Ector.join(:carts)
        end,
        [],
        __ENV__
      )
    end
  end
end
