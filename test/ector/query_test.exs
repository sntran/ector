defmodule Ector.QueryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Ector.Query

  require Ecto.Query
  require Ector.Query

  @physical_fields [:__id__, :label, :source_id, :target_id]

  defmodule Cart do
    use Ector.Node

    schema do
      field(:title, :string)
      field(:status, :string)
    end
  end

  defmodule HasCart do
    use Ector.Edge

    schema do
      field(:status, :string)
    end
  end

  defmodule User do
    use Ector.Node

    schema do
      field(:email, :string)
      field(:status, :string)
      field(:custom_field, :string)

      has_many(:carts, Cart, through: HasCart)
    end
  end

  defmodule PlainSchema do
    use Ecto.Schema

    schema "plain_schemas" do
      field(:status, :string)
    end
  end

  defmodule ForwardQuery do
    require Ector.Query

    def query do
      Ector.Query.from(target in Ector.QueryTest.ForwardTarget)
    end
  end

  defmodule ForwardTarget do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  defmodule BareForwardQuery do
    require Ector.Query

    def query do
      Ector.Query.from(Ector.QueryTest.BareForwardTarget)
    end
  end

  defmodule BareForwardTarget do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  defmodule IncomingUser do
    use Ector.Node

    schema do
      field(:email, :string)

      belongs_to(:cart, Cart, through: "has_cart")
    end
  end

  defmodule AtomThroughUser do
    use Ector.Node

    schema do
      has_many(:legacy_carts, Cart, through: :legacy_cart)
    end
  end

  defmodule BinaryThroughUser do
    use Ector.Node

    schema do
      has_many(:legacy_carts, Cart, through: "legacy_cart")
    end
  end

  defmodule NamedEdgeUser do
    use Ector.Node

    schema do
      has_many(:line_items, Cart)
    end
  end

  defmodule OrphanParent do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  defmodule OrphanChild do
    use Ector.Node

    schema do
      belongs_to(:orphan_parent, OrphanParent)
    end
  end

  defmodule NativeTarget do
    use Ector.Node

    schema do
      field(:name, :string)
      field(:native_has_parent_id, Ecto.UUID)
    end
  end

  defmodule NativeHasParent do
    use Ector.Node

    schema do
      Ecto.Schema.has_many(:native_targets, NativeTarget,
        foreign_key: :native_has_parent_id,
        references: :__id__
      )
    end
  end

  defmodule ManyToManyTag do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  defmodule ManyToManyArticle do
    use Ector.Node

    schema do
      Ecto.Schema.many_to_many(:tags, ManyToManyTag, join_through: "articles_tags")
    end
  end

  defmodule ImplicitParent do
    use Ector.Node

    schema do
      has_many(:implicit_children, Ector.QueryTest.ImplicitChild)
    end
  end

  defmodule ImplicitChild do
    use Ector.Node

    schema do
      belongs_to(:implicit_parent, Ector.QueryTest.ImplicitParent)
    end
  end

  defmodule InvalidThroughUser do
    use Ector.Node

    schema do
      has_many(:invalid_carts, Cart, through: 123)
    end
  end

  defmodule ChainProduct do
    use Ector.Node

    schema do
      field(:name, :string)
    end
  end

  defmodule ChainOffer do
    use Ector.Node

    schema do
      field(:price, :integer)

      belongs_to(:product, ChainProduct, through: :product_offers)
    end
  end

  defmodule ChainItem do
    use Ector.Node

    schema do
      field(:quantity, :integer)

      belongs_to(:offer, ChainOffer, through: :cart_item_offers)
    end
  end

  defmodule ChainCart do
    use Ector.Node

    schema do
      has_many(:items, ChainItem, through: :cart_items)
    end
  end

  test "from/1 targets the shared nodes table and preserves the domain module" do
    query = Ector.Query.from(u in User)

    assert query.from.source == {"nodes", User}
    assert [%Ecto.Query.BooleanExpr{} = label_filter] = query.wheres
    assert label_filter.params == [{"User", {0, :label}}]
    assert physical_field_access?(label_filter.expr, :label)
  end

  test "from/1 accepts bare Ector modules and falls back for non-Ector sources" do
    bare_query = Ector.Query.from(User)

    assert bare_query.from.source == {"nodes", User}
    assert [%Ecto.Query.BooleanExpr{}] = bare_query.wheres

    bare_plain_query = Ector.Query.from(PlainSchema)

    assert bare_plain_query.from.source == {"plain_schemas", PlainSchema}
    assert bare_plain_query.wheres == []

    plain_query = Ector.Query.from(plain in PlainSchema, where: plain.status == "active")

    assert plain_query.from.source == {"plain_schemas", PlainSchema}
    assert json_path_access?(hd(plain_query.wheres).expr, "status")

    string_source_query = Ector.Query.from(row in "plain_schemas", where: row.status == "active")

    assert string_source_query.from.source == {"plain_schemas", nil}
    assert json_path_access?(hd(string_source_query.wheres).expr, "status")

    bare_string_query = Ector.Query.from("plain_schemas")

    assert bare_string_query.from.source == {"plain_schemas", nil}
    assert bare_string_query.wheres == []
  end

  test "from/1 defers Ector schema detection for forward module references" do
    query = ForwardQuery.query()

    assert query.from.source == {"nodes", ForwardTarget}
    assert [%Ecto.Query.BooleanExpr{} = label_filter] = query.wheres
    assert label_filter.params == [{"ForwardTarget", {0, :label}}]
  end

  test "from/1 defers Ector schema detection for bare forward module references" do
    query = BareForwardQuery.query()

    assert query.from.source == {"nodes", BareForwardTarget}
    assert [%Ecto.Query.BooleanExpr{} = label_filter] = query.wheres
    assert label_filter.params == [{"BareForwardTarget", {0, :label}}]
  end

  test "from/1 supports list-shaped binding ASTs" do
    source_ast = {:in, [], [[{:user, [], Elixir}], User]}

    quoted =
      {:__block__, [],
       [
         {:require, [], [Ector.Query]},
         {{:., [], [Ector.Query, :from]}, [], [source_ast]}
       ]}

    {query, _binding} = Code.eval_quoted(quoted, [], __ENV__)

    assert query.from.source == {"nodes", User}
    assert [%Ecto.Query.BooleanExpr{}] = query.wheres
  end

  test "from/2 rejects non-keyword options" do
    assert_raise ArgumentError, ~r/second argument to `from`/, fn ->
      Code.eval_quoted(
        quote do
          require Ector.Query
          Ector.Query.from(user in unquote(User), :not_a_keyword)
        end,
        [],
        __ENV__
      )
    end
  end

  test "query default arities rewrite through Ecto.Query" do
    {query, _binding} =
      Code.eval_quoted(
        quote do
          require Ector.Query

          Ector.Query.from(user in unquote(User))
          |> Ector.Query.where(true)
          |> Ector.Query.or_where(false)
          |> Ector.Query.group_by(fragment("1"))
          |> Ector.Query.having(true)
          |> Ector.Query.or_having(false)
          |> Ector.Query.order_by(fragment("1"))
          |> Ector.Query.select(1)
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
          require Ector.Query
          Ector.Query.dynamic(true)
        end,
        [],
        __ENV__
      )

    assert %Ecto.Query.DynamicExpr{} = dynamic_expr
  end

  property "where/3 rewrites arbitrary domain fields to properties JSON paths" do
    check all(field <- field_name_gen(), max_runs: 25) do
      query = query_with_rewritten_clause(:where, field)

      assert json_path_access?(List.last(query.wheres).expr, Atom.to_string(field))
    end
  end

  property "select/3 rewrites arbitrary domain fields to properties JSON paths" do
    check all(field <- field_name_gen(), max_runs: 25) do
      query = query_with_rewritten_clause(:select, field)

      assert json_path_access?(query.select.expr, Atom.to_string(field))
    end
  end

  property "order_by/3 rewrites arbitrary domain fields to properties JSON paths" do
    check all(field <- field_name_gen(), max_runs: 25) do
      query = query_with_rewritten_clause(:order_by, field)

      assert json_path_access?(hd(query.order_bys).expr, Atom.to_string(field))
    end
  end

  property "group_by/3 rewrites arbitrary domain fields to properties JSON paths" do
    check all(field <- field_name_gen(), max_runs: 25) do
      query = query_with_rewritten_clause(:group_by, field)

      assert json_path_access?(hd(query.group_bys).expr, Atom.to_string(field))
    end
  end

  test "the JSON rewriter leaves physical fields unchanged" do
    for field <- @physical_fields do
      query = query_with_rewritten_clause(:where, field)

      refute json_path_access?(List.last(query.wheres).expr, Atom.to_string(field))
      assert physical_field_access?(List.last(query.wheres).expr, field)
    end
  end

  test "the JSON rewriter maps domain id to the properties payload" do
    query = query_with_rewritten_clause(:where, :id)

    assert json_path_access?(List.last(query.wheres).expr, "id")
    refute physical_field_access?(List.last(query.wheres).expr, :id)
  end

  test "the JSON rewriter leaves pinned values untouched and rewrites fragment fields" do
    value = "active"
    query = Ector.Query.from(c in User)
    pinned_query = Ector.Query.where(query, [c], c.status == ^value)
    fragment_query = Ector.Query.where(query, [c], fragment("? = ?", c.status, ^value))

    pinned_filter = List.last(pinned_query.wheres)
    fragment_filter = List.last(fragment_query.wheres)

    assert pinned_filter.params == [{"active", :any}]
    assert json_path_access?(pinned_filter.expr, "status")

    assert json_path_access?(fragment_filter.expr, "status")
    refute physical_field_access?(fragment_filter.expr, :status)
  end

  test "dynamic/2 rewrites domain fields to properties JSON paths" do
    dynamic_expr = Ector.Query.dynamic([u], u.status == "active")
    {expr, params, subqueries, aliases} = dynamic_expr.fun.(%Ecto.Query{})

    assert params == []
    assert subqueries == []
    assert aliases == %{}
    assert json_path_access?(expr, "status")
  end

  test "where/2 accepts rewritten dynamic expressions" do
    dynamic_expr = Ector.Query.dynamic([u], u.status == "active")

    query =
      Ector.Query.from(u in User)
      |> Ector.Query.where(^dynamic_expr)

    assert json_path_access?(List.last(query.wheres).expr, "status")
  end

  test "pinned map field access is shielded from the rewriter" do
    user = %{status: "active"}

    query =
      Ector.Query.from(c in User)
      |> Ector.Query.where([c], ^user.status == "active")

    filter = List.last(query.wheres)

    assert [{"active", _type}] = filter.params
    refute json_path_access?(filter.expr, "status")
    refute physical_field_access?(filter.expr, :status)
  end

  test "or_where/3 rewrites domain fields and keeps OR semantics" do
    query =
      Ector.Query.from(c in User)
      |> Ector.Query.where([c], c.status == "active")
      |> Ector.Query.or_where([c], c.email == "ada@example.com")

    assert %Ecto.Query.BooleanExpr{op: :or} = filter = List.last(query.wheres)
    assert json_path_access?(filter.expr, "email")
  end

  test "or_having/3 rewrites domain fields and keeps OR semantics" do
    query =
      Ector.Query.from(c in User)
      |> Ector.Query.group_by([c], c.status)
      |> Ector.Query.having([c], c.status == "active")
      |> Ector.Query.or_having([c], c.email == "ada@example.com")

    assert %Ecto.Query.BooleanExpr{op: :or} = filter = List.last(query.havings)
    assert json_path_access?(filter.expr, "email")
  end

  test "join/3 expands graph joins into deterministic edge and target node joins" do
    query = Ector.Query.from(u in User)
    joined = Ector.Query.join(query, :carts, as: :cart)

    assert [edge_join, target_join] = joined.joins
    assert edge_join.qual == :inner
    assert edge_join.source == {"edges", Ector.Edge}
    assert generated_edge_alias?(edge_join.as, :cart)
    assert edge_join.prefix == nil
    assert join_field_comparison?(edge_join.on.expr, 1, :source_id, 0, :__id__)
    refute physical_field_access?(edge_join.on.expr, :id)
    assert Enum.any?(edge_join.on.params, &match?({"HAS_CART", _type}, &1))

    assert target_join.qual == :inner
    assert target_join.source == {"nodes", Cart}
    assert target_join.as == :cart
    assert target_join.prefix == nil
    assert join_field_comparison?(target_join.on.expr, 2, :__id__, 1, :target_id)
    refute physical_field_access?(target_join.on.expr, :id)
    assert physical_field_access?(target_join.on.expr, :label)
    assert Enum.any?(target_join.on.params, &match?({"Cart", _type}, &1))

    assert joined.aliases[edge_join.as] == 1
    assert joined.aliases.cart == 2
  end

  test "join/3 avoids collisions with user aliases that match old edge aliases" do
    query =
      Ector.Query.from(u in User)
      |> Ecto.Query.join(:inner, [u], marker in "nodes", as: :__edge_cart, on: true)

    joined = Ector.Query.join(query, :carts, as: :cart)

    assert [user_join, edge_join, target_join] = joined.joins
    assert user_join.as == :__edge_cart
    assert generated_edge_alias?(edge_join.as, :cart)
    refute edge_join.as == :__edge_cart
    assert target_join.as == :cart
    assert join_field_comparison?(edge_join.on.expr, 2, :source_id, 0, :__id__)
    assert join_field_comparison?(target_join.on.expr, 3, :__id__, 2, :target_id)

    assert joined.aliases.__edge_cart == 1
    assert joined.aliases[edge_join.as] == 2
    assert joined.aliases.cart == 3
  end

  test "join/3 expands incoming graph joins and validates macro arguments" do
    incoming_join =
      IncomingUser
      |> Ector.Query.from()
      |> Ector.Query.join(:cart, as: :cart)

    assert [edge_join, target_join] = incoming_join.joins
    assert join_field_comparison?(edge_join.on.expr, 1, :target_id, 0, :__id__)
    assert join_field_comparison?(target_join.on.expr, 2, :__id__, 1, :source_id)

    query = Ector.Query.from(u in User)

    assert_raise ArgumentError, ~r/compile time atom `as:` alias/, fn ->
      Code.eval_quoted(
        quote do
          require Ector.Query
          Ector.Query.join(unquote(Macro.escape(query)), :carts, as: "cart")
        end,
        [],
        __ENV__
      )
    end

    assert_raise ArgumentError, ~r/require an `as:` alias/, fn ->
      Code.eval_quoted(
        quote do
          require Ector.Query
          Ector.Query.join(unquote(Macro.escape(query)), :carts)
        end,
        [],
        __ENV__
      )
    end

    assert_raise ArgumentError, ~r/compile time atom association name/, fn ->
      Code.eval_quoted(
        quote do
          require Ector.Query
          Ector.Query.join(unquote(Macro.escape(query)), "carts", as: :cart)
        end,
        [],
        __ENV__
      )
    end

    assert_raise ArgumentError, ~r/compile time keyword list/, fn ->
      Code.eval_quoted(
        quote do
          require Ector.Query
          Ector.Query.join(unquote(Macro.escape(query)), :carts, :not_opts)
        end,
        [],
        __ENV__
      )
    end

    assert_raise ArgumentError, ~r/`from:` to be a compile time atom alias/, fn ->
      Code.eval_quoted(
        quote do
          require Ector.Query
          Ector.Query.join(unquote(Macro.escape(query)), :carts, as: :cart, from: "root")
        end,
        [],
        __ENV__
      )
    end
  end

  test "join/3 can continue from a previous named target binding" do
    root_joined =
      Ector.Query.from(u in User, as: :root)
      |> Ector.Query.join(:carts, as: :cart, from: :root)

    assert [root_edge_join, root_target_join] = root_joined.joins
    assert join_field_comparison?(root_edge_join.on.expr, 1, :source_id, 0, :__id__)
    assert root_target_join.as == :cart

    joined =
      ChainCart
      |> Ector.Query.from()
      |> Ector.Query.join(:items, as: :item)
      |> Ector.Query.join(:offer, as: :offer, from: :item)
      |> Ector.Query.join(:product, as: :product, from: :offer)

    assert length(joined.joins) == 6
    assert joined.aliases.item == 2
    assert joined.aliases.offer == 4
    assert joined.aliases.product == 6

    [cart_item_edge, item_join, offer_item_edge, offer_join, product_offer_edge, product_join] =
      joined.joins

    assert cart_item_edge.source == {"edges", Ector.Edge}
    assert item_join.source == {"nodes", ChainItem}
    assert Enum.any?(cart_item_edge.on.params, &match?({"CART_ITEMS", _type}, &1))

    assert offer_item_edge.source == {"edges", Ector.Edge}
    assert offer_join.source == {"nodes", ChainOffer}
    assert Enum.any?(offer_item_edge.on.params, &match?({"CART_ITEM_OFFERS", _type}, &1))
    assert join_field_comparison?(offer_item_edge.on.expr, 3, :target_id, 2, :__id__)
    assert join_field_comparison?(offer_join.on.expr, 4, :__id__, 3, :source_id)

    assert product_offer_edge.source == {"edges", Ector.Edge}
    assert product_join.source == {"nodes", ChainProduct}
    assert Enum.any?(product_offer_edge.on.params, &match?({"PRODUCT_OFFERS", _type}, &1))
    assert join_field_comparison?(product_offer_edge.on.expr, 5, :target_id, 4, :__id__)
    assert join_field_comparison?(product_join.on.expr, 6, :__id__, 5, :source_id)

    assert_raise ArgumentError, ~r/unknown Ector join source alias :missing/, fn ->
      ChainCart
      |> Ector.Query.from()
      |> Ector.Query.join(:offer, as: :offer, from: :missing)
    end

    assert_raise ArgumentError, ~r/unknown Ector join source alias :ghost/, fn ->
      User
      |> Ector.Query.from()
      |> Map.put(:aliases, %{ghost: 99})
      |> Ector.Query.join(:carts, as: :cart, from: :ghost)
    end
  end

  test "join/3 validates associations and Ector query sources" do
    query = Ector.Query.from(u in User)

    assert_raise ArgumentError, ~r/unknown Ector association/, fn ->
      Ector.Query.join(query, :unknown, as: :cart)
    end

    assert_raise ArgumentError, ~r/expected an Ector schema module/, fn ->
      PlainSchema
      |> Ecto.Query.from()
      |> Ector.Query.join(:carts, as: :cart)
    end

    assert_raise ArgumentError, ~r/expected an Ector query source/, fn ->
      Ector.Query.join(%Ecto.Query{from: %Ecto.Query.FromExpr{source: "plain"}}, :carts,
        as: :cart
      )
    end

    assert_raise ArgumentError, ~r/expected an Ector query source, got: nil/, fn ->
      Ector.Query.join(%Ecto.Query{}, :carts, as: :cart)
    end
  end

  test "join/3 resolves module atom binary named and invalid edge labels" do
    assert_join_edge_label(
      User |> Ector.Query.from() |> Ector.Query.join(:carts, as: :cart),
      "HAS_CART"
    )

    assert_join_edge_label(
      AtomThroughUser |> Ector.Query.from() |> Ector.Query.join(:legacy_carts, as: :cart),
      "LEGACY_CART"
    )

    assert_join_edge_label(
      BinaryThroughUser |> Ector.Query.from() |> Ector.Query.join(:legacy_carts, as: :cart),
      "LEGACY_CART"
    )

    assert_join_edge_label(
      NamedEdgeUser |> Ector.Query.from() |> Ector.Query.join(:line_items, as: :cart),
      "LINE_ITEMS"
    )

    assert_join_edge_label(
      OrphanChild |> Ector.Query.from() |> Ector.Query.join(:orphan_parent, as: :parent),
      "ORPHAN_PARENT"
    )

    assert_join_edge_label(
      NativeHasParent
      |> Ector.Query.from()
      |> Ector.Query.join(:native_targets, as: :native_target),
      "NATIVE_TARGETS"
    )

    assert_join_edge_label(
      ImplicitParent
      |> Ector.Query.from()
      |> Ector.Query.join(:implicit_children, as: :child),
      "IMPLICIT_CHILDREN"
    )

    assert_join_edge_label(
      ImplicitChild
      |> Ector.Query.from()
      |> Ector.Query.join(:implicit_parent, as: :parent),
      "IMPLICIT_CHILDREN"
    )

    assert_raise ArgumentError, ~r/unsupported Ector edge label source/, fn ->
      InvalidThroughUser
      |> Ector.Query.from()
      |> Ector.Query.join(:invalid_carts, as: :cart)
    end

    assert_raise ArgumentError, ~r/unknown Ector association :tags/, fn ->
      ManyToManyArticle
      |> Ector.Query.from()
      |> Ector.Query.join(:tags, as: :tag)
    end
  end

  defp assert_join_edge_label(joined, edge_label) when is_binary(edge_label) do
    assert [edge_join, _target_join] = joined.joins
    assert Enum.any?(edge_join.on.params, &match?({^edge_label, _type}, &1))
  end

  defp query_with_rewritten_clause(kind, field) when is_atom(field) do
    field_access = field_access_ast(field)
    comparison = {:==, [], [field_access, "active"]}

    quoted =
      case kind do
        :where ->
          quote do
            query = Ector.Query.from(c in unquote(User))
            Ector.Query.where(query, [c], unquote(comparison))
          end

        :select ->
          quote do
            query = Ector.Query.from(c in unquote(User))
            Ector.Query.select(query, [c], unquote(field_access))
          end

        :order_by ->
          quote do
            query = Ector.Query.from(c in unquote(User))
            Ector.Query.order_by(query, [c], unquote(field_access))
          end

        :group_by ->
          quote do
            query = Ector.Query.from(c in unquote(User))
            Ector.Query.group_by(query, [c], unquote(field_access))
          end
      end

    {query, _binding} = Code.eval_quoted(quoted, [], __ENV__)
    query
  end

  defp field_access_ast(field) when is_atom(field) do
    {{:., [], [{:c, [], Elixir}, field]}, [], []}
  end

  defp json_path_access?(ast, field) when is_binary(field) do
    ast
    |> normalize_metadata()
    |> ast_contains?(fn
      {:json_extract_path, [],
       [{{:., [], [{:&, [], [_binding_index]}, :properties]}, [], []}, [^field]]} ->
        true

      _other ->
        false
    end)
  end

  defp physical_field_access?(ast, field) when is_atom(field) do
    ast
    |> normalize_metadata()
    |> ast_contains?(fn
      {{:., [], [{:&, [], [_binding_index]}, ^field]}, [], []} -> true
      _other -> false
    end)
  end

  defp join_field_comparison?(ast, left_index, left_field, right_index, right_field) do
    ast
    |> normalize_metadata()
    |> ast_contains?(fn
      {:==, [],
       [
         {{:., [], [{:&, [], [^left_index]}, ^left_field]}, [], []},
         {{:., [], [{:&, [], [^right_index]}, ^right_field]}, [], []}
       ]} ->
        true

      {:==, [],
       [
         {{:., [], [{:&, [], [^right_index]}, ^right_field]}, [], []},
         {{:., [], [{:&, [], [^left_index]}, ^left_field]}, [], []}
       ]} ->
        true

      _other ->
        false
    end)
  end

  defp generated_edge_alias?(alias_name, target_alias)
       when is_atom(alias_name) and is_atom(target_alias) do
    Regex.match?(~r/^__edge_#{target_alias}_[1-9][0-9]*$/, Atom.to_string(alias_name))
  end

  defp ast_contains?(ast, predicate) when is_function(predicate, 1) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end

  defp normalize_metadata(ast) do
    Macro.prewalk(ast, fn
      {{:., _dot_meta, dot_args}, _call_meta, call_args} ->
        {{:., [], dot_args}, [], call_args}

      {name, _meta, args} when is_atom(name) and is_list(args) ->
        {name, [], args}

      other ->
        other
    end)
  end

  defp field_name_gen do
    StreamData.bind(StreamData.member_of(letter_strings()), fn first ->
      StreamData.map(
        StreamData.list_of(StreamData.member_of(identifier_strings()), max_length: 8),
        fn rest ->
          String.to_atom(Enum.join([first | rest]))
        end
      )
    end)
    |> StreamData.filter(&(&1 not in @physical_fields and &1 != :properties))
  end

  defp letter_strings, do: Enum.map(?a..?z, &<<&1::utf8>>)
  defp identifier_strings, do: letter_strings() ++ Enum.map(?0..?9, &<<&1::utf8>>) ++ ["_"]
end
