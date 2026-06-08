defmodule StoreIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Store.Catalog
  alias Store.Ector, as: EctorStore
  alias Store.Ector.Dynamic
  alias Store.Relational, as: RelationalStore

  require Ector

  setup do
    Store.Sandbox.reset!()

    on_exit(fn -> Store.Sandbox.drop!() end)

    :ok
  end

  test "filters and filtered bulk updates return identical business data" do
    Catalog.seed_relational_catalog(Store.RelationalRepo)
    Catalog.seed_ector_catalog(Store.EctorRepo)

    assert Catalog.active_book_names_relational(Store.RelationalRepo) == ["Clean Code", "SICP"]
    assert Catalog.active_book_names_ector(Store.EctorRepo) == ["Clean Code", "SICP"]

    assert {2, _} = Catalog.archive_active_books_relational(Store.RelationalRepo)
    assert {2, _} = Catalog.archive_active_books_ector(Store.EctorRepo)

    assert Catalog.active_book_names_relational(Store.RelationalRepo) == []
    assert Catalog.active_book_names_ector(Store.EctorRepo) == []
  end

  test "cart association load matches relational joins and Ector hidden edge joins" do
    Catalog.seed_relational_cart(Store.RelationalRepo)
    assert {:ok, _customer} = Catalog.seed_ector_cart(Store.EctorRepo)

    expected = ["Clean Code", "Gel Pen"]

    assert Catalog.cart_product_names_relational(Store.RelationalRepo) == expected
    assert Catalog.cart_product_names_ector(Store.EctorRepo) == expected

    relational_cart = Catalog.load_relational_cart(Store.RelationalRepo)
    assert Enum.map(relational_cart.cart_items, & &1.product.name) |> Enum.sort() == expected
    assert Catalog.load_ector_cart_items(Store.EctorRepo) == expected
  end

  test "deep Ector graph inserts persist typed edge payloads" do
    assert {:ok, %EctorStore.Customer{id: "cust-1", email: "ada@example.com"}} =
             Catalog.seed_ector_cart(Store.EctorRepo)

    assert [%EctorStore.Customer{name: "Ada Lovelace"}] = Store.EctorRepo.all(EctorStore.Customer)

    assert [%EctorStore.Cart{id: "cart-1", status: "active", currency: "USD"}] =
             Store.EctorRepo.all(EctorStore.Cart)

    assert Store.EctorRepo.all(EctorStore.Product)
           |> Enum.map(& &1.name)
           |> Enum.sort() == ["Clean Code", "Gel Pen"]

    assert [%EctorStore.HasCart{created_via: "web"}] = Store.EctorRepo.all(EctorStore.HasCart)

    assert Store.EctorRepo.all(EctorStore.Contains)
           |> Enum.map(&{&1.quantity, &1.unit_price, &1.pricing})
           |> Enum.sort() == [
             {1, 30.0,
              %{
                "currency" => "USD",
                "discounts" => %{"amount" => 0.0, "code" => "NONE"},
                "list" => 30.0
              }},
             {3, 2.5,
              %{
                "currency" => "USD",
                "discounts" => %{"amount" => 0.25, "code" => "BULK"},
                "list" => 2.5
              }}
           ]

    assert node_count() == 4
    assert edge_count() == 3
  end

  test "deleting a graph node cascades hidden edge rows" do
    assert {:ok, _customer} = Catalog.seed_ector_cart(Store.EctorRepo)
    assert [%EctorStore.Cart{} = cart] = Store.EctorRepo.all(EctorStore.Cart)
    assert edge_count() == 3

    assert {:ok, %EctorStore.Cart{}} = Store.EctorRepo.delete(cart)

    assert edge_count() == 0
    assert [%EctorStore.Customer{}] = Store.EctorRepo.all(EctorStore.Customer)
    assert length(Store.EctorRepo.all(EctorStore.Product)) == 2
  end

  test "Ector JSON product indexes are installed and enforce scoped SKU uniqueness" do
    index_sql = ector_node_index_sql()

    case Store.adapter_name() do
      :sqlite ->
        assert Enum.any?(
                 index_sql,
                 &(&1 =~ "json_extract(properties, '$.sku')" and &1 =~ "Product")
               )

        assert Enum.any?(
                 index_sql,
                 &(&1 =~ "json_extract(properties, '$.category')" and
                     &1 =~ "json_extract(properties, '$.status')" and &1 =~ "Product")
               )

      :postgres ->
        assert Enum.any?(index_sql, &(&1 =~ "properties" and &1 =~ "sku" and &1 =~ "Product"))

        assert Enum.any?(
                 index_sql,
                 &(&1 =~ "properties" and &1 =~ "category" and &1 =~ "status" and &1 =~ "Product")
               )
    end

    Catalog.seed_ector_catalog(Store.EctorRepo)

    if Store.adapter_name() == :sqlite do
      plan =
        Store.EctorRepo.query!(
          "EXPLAIN QUERY PLAN SELECT json_extract(properties, '$.name') FROM nodes WHERE label = ? AND json_extract(properties, '$.category') = ? AND json_extract(properties, '$.status') = ?",
          ["Product", "books", "active"]
        ).rows
        |> List.flatten()
        |> Enum.filter(&is_binary/1)
        |> Enum.join("\n")

      assert plan =~
               "USING INDEX nodes_json_extract_properties_____category_json_extract_properties_____status_index"
    end

    duplicate_product =
      EctorStore.Product.changeset(%EctorStore.Product{}, %{
        id: "duplicate-sku",
        sku: "SKU-SICP",
        name: "Duplicate SICP",
        category: "books",
        status: "active",
        price: 11.0
      })

    try do
      Store.EctorRepo.insert(duplicate_product)
      flunk("expected duplicate Ector product SKU to violate the unique JSON index")
    rescue
      exception ->
        message = exception |> Exception.message() |> String.downcase()

        assert message =~ "unique"
        assert message =~ "sku"
    end
  end

  test "three-field filtered bulk updates preserve relational and Ector parity" do
    Catalog.seed_relational_catalog(Store.RelationalRepo)
    Catalog.seed_ector_catalog(Store.EctorRepo)

    assert {2, _} =
             Store.RelationalRepo.update_all(
               from(p in RelationalStore.Product,
                 where: p.category == "books" and p.status == "active"
               ),
               set: [status: "clearance", category: "clearance", price: 1.25]
             )

    assert {2, _} =
             EctorStore.Product
             |> Ector.from()
             |> Ector.where([p], p.category == ^"books" and p.status == ^"active")
             |> Store.EctorRepo.update_all(
               set: [status: "clearance", category: "clearance", price: 1.25]
             )

    assert relational_product_snapshot() == ector_product_snapshot()
  end

  test "dynamic Ector schema accepts unmigrated nodes and runtime attributes" do
    result = Dynamic.run(Store.EctorRepo)

    assert %Store.Ector.Product{id: "dyn-prod-1", sku: "SKU-DYN"} = result.product
    assert %Dynamic.Review{id: "review-1", sku: "SKU-DYN", rating: 5} = result.review

    assert %{
             sku: "SKU-DYN",
             warranty_months: 24,
             clearance: clearance
           } = result.runtime_attributes

    assert clearance in [true, 1]
  end

  defp node_count do
    Store.EctorRepo.query!("SELECT COUNT(*) FROM nodes").rows
    |> count_result()
  end

  defp edge_count do
    Store.EctorRepo.query!("SELECT COUNT(*) FROM edges").rows
    |> count_result()
  end

  defp count_result([[count]]) when is_integer(count), do: count

  defp ector_node_index_sql do
    rows =
      case Store.adapter_name() do
        :sqlite ->
          Store.EctorRepo.query!(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'nodes'"
          ).rows

        :postgres ->
          Store.EctorRepo.query!(
            "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'nodes'"
          ).rows
      end

    rows
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end

  defp relational_product_snapshot do
    Store.RelationalRepo.all(
      from(p in RelationalStore.Product,
        select: {p.id, p.category, p.status, p.price},
        order_by: p.id
      )
    )
  end

  defp ector_product_snapshot do
    EctorStore.Product
    |> Ector.from()
    |> Ector.select([p], {p.id, p.category, p.status, p.price})
    |> Store.EctorRepo.all()
    |> Enum.sort_by(&elem(&1, 0))
  end
end
