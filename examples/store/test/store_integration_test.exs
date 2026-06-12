defmodule StoreIntegrationTest do
  use ExUnit.Case, async: false

  alias Store.Catalog
  alias Store.Catalog.{Offer, Product}
  alias Store.Checkout
  alias Store.Checkout.{Cart, CartItem}
  alias Store.Repo
  alias Store.Storage

  require Ector

  setup do
    Store.Sandbox.reset!()

    on_exit(fn -> Store.Sandbox.drop!() end)

    :ok
  end

  test "domain changesets validate storefront payloads without field migrations" do
    assert Product.changeset(%Product{}, %{
             id: "product-1",
             name: "Merino Hoodie",
             description: "Warm hoodie",
             images: ["https://example.com/hoodie.png"]
           }).valid?

    refute Product.changeset(%Product{}, %{
             id: "product-1",
             name: "Merino Hoodie",
             description: "Warm hoodie",
             images: []
           }).valid?

    assert Offer.changeset(%Offer{}, %{
             id: "offer-1",
             product_id: "product-1",
             offered_by: "Northstar Supply",
             price: 12_500,
             quantity: 9,
             product_name: "Merino Hoodie",
             product_description: "Warm hoodie"
           }).valid?

    assert Cart.changeset(%Cart{}, %{id: "cart-1", status: "active"}).valid?
    refute Cart.changeset(%Cart{}, %{id: "cart-1", status: "stale"}).valid?

    assert CartItem.changeset(%CartItem{}, %{
             id: "item-1",
             quantity: 2,
             price_at_addition: 12_500
           }).valid?
  end

  test "migrations install only Ector tables and scoped Offer JSON uniqueness" do
    assert table_names() == ["edges", "nodes", "store_schema_migrations"]

    index_sql = node_index_sql()

    case Store.adapter_name() do
      :sqlite ->
        assert Enum.any?(
                 index_sql,
                 &(&1 =~ "store_offers_product_id_offered_by_uidx" and
                     &1 =~ "json_extract(properties, '$.product_id')" and
                     &1 =~ "json_extract(properties, '$.offered_by')" and &1 =~ "Offer")
               )

      :postgres ->
        assert Enum.any?(
                 index_sql,
                 &(&1 =~ "store_offers_product_id_offered_by_uidx" and
                     &1 =~ "properties" and &1 =~ "product_id" and &1 =~ "offered_by" and
                     &1 =~ "Offer")
               )
    end
  end

  test "Offer uniqueness is scoped to the Offer label" do
    product_storage_id = Storage.uuidv7()
    first_offer_storage_id = Storage.uuidv7()

    Storage.insert_nodes!([
      Storage.node_row(
        Product,
        %{
          id: "product-1",
          name: "Merino Hoodie",
          description: "Warm hoodie",
          images: ["https://example.com/hoodie.png"]
        },
        product_storage_id
      ),
      Storage.node_row(Offer, offer_attrs("offer-1", "product-1"), first_offer_storage_id),
      Storage.node_row(Cart, %{
        id: "cart-shadow",
        status: "active",
        product_id: "product-1",
        offered_by: "Northstar Supply"
      })
    ])

    duplicate_offer =
      Storage.node_row(Offer, offer_attrs("offer-duplicate", "product-1"), Storage.uuidv7())

    try do
      Storage.insert_nodes!([duplicate_offer])
      flunk("expected duplicate Offer product/vendor properties to violate the unique index")
    rescue
      exception ->
        message = exception |> Exception.message() |> String.downcase()

        assert message =~ "unique"
        assert message =~ "store_offers_product_id_offered_by_uidx"
    end
  end

  test "list_offers searches denormalized Offer text and paginates by descending __id__" do
    seed_storefront_fixture!()

    first_page = Catalog.list_offers(limit: 2, search: "hoodie")

    assert length(first_page.entries) == 2
    assert first_page.next_cursor
    assert Enum.all?(first_page.entries, &String.contains?(&1.product_name, "Hoodie"))
    refute Enum.any?(first_page.entries, &Map.has_key?(&1, :images))

    assert Enum.map(first_page.entries, & &1.cursor) ==
             first_page.entries |> Enum.map(& &1.cursor) |> Enum.sort(:desc)

    second_page = Catalog.list_offers(limit: 2, search: "hoodie", cursor: first_page.next_cursor)

    assert length(second_page.entries) == 1
    assert second_page.next_cursor == nil
    assert hd(second_page.entries).cursor < List.last(first_page.entries).cursor

    previous_page =
      Catalog.list_offers(limit: 2, search: "hoodie", cursor: second_page.previous_cursor)

    assert Enum.map(previous_page.entries, & &1.id) == Enum.map(first_page.entries, & &1.id)

    vendor_page = Catalog.list_offers(offered_by: "Vector Market", min_price: 8_000)
    assert Enum.map(vendor_page.entries, & &1.id) == ["offer-2"]
  end

  test "get_cart_summary preloads Cart -> CartItem -> Offer -> Product" do
    seed_storefront_fixture!()

    assert %{
             id: "cart-1",
             status: "active",
             item_count: 3,
             subtotal: 45_600,
             items: [
               %{
                 item_id: "item-1",
                 quantity: 2,
                 price_at_addition: 12_500,
                 offer: %{id: "offer-1", product_name: "Merino Hoodie / Crimson"},
                 product: %{images: ["https://example.com/hoodie-crimson.png"]}
               },
               %{
                 item_id: "item-2",
                 quantity: 1,
                 price_at_addition: 13_100,
                 offer: %{id: "offer-2", product_name: "Merino Hoodie / Indigo"},
                 product: %{images: ["https://example.com/hoodie-indigo.png"]}
               },
               %{
                 item_id: "item-3",
                 quantity: 3,
                 price_at_addition: 2_500,
                 offer: %{id: "offer-4", product_name: "Trail Socks / Pine"},
                 product: %{images: ["https://example.com/socks-pine.png"]}
               }
             ]
           } = Checkout.get_cart_summary("cart-1")

    assert Checkout.get_cart_summary("missing-cart") == nil
  end

  test "add_offer_to_cart merges an existing offer line by increasing quantity" do
    seed_storefront_fixture!()

    summary = Checkout.add_offer_to_cart("cart-1", "offer-2", 2)

    assert summary.item_count == 3
    assert summary.quantity_total == 8
    assert summary.subtotal == 71_800

    assert [%{quantity: 3, price_at_addition: 13_100}] =
             Enum.filter(summary.items, &(&1.offer.id == "offer-2"))
  end

  test "process_checkout atomically decrements offer quantities and converts the cart" do
    seed_storefront_fixture!()

    assert {:ok, %{status: "converted", quantity_total: 6}} = Checkout.process_checkout("cart-1")

    assert Catalog.get_offer_stock("offer-1") == 8
    assert Catalog.get_offer_stock("offer-2") == 7
    assert Catalog.get_offer_stock("offer-4") == 37
  end

  test "process_checkout rolls back all stock decrements when an offer is out of stock" do
    seed_storefront_fixture!()
    set_offer_quantity("offer-4", 2)

    assert {:error, :out_of_stock} = Checkout.process_checkout("cart-1")

    assert Checkout.get_cart_summary("cart-1").status == "active"
    assert Catalog.get_offer_stock("offer-1") == 10
    assert Catalog.get_offer_stock("offer-2") == 8
    assert Catalog.get_offer_stock("offer-4") == 2
  end

  defp seed_storefront_fixture! do
    product_offer_label = Storage.edge_label!(Product, :offers)
    cart_item_label = Storage.edge_label!(Cart, :items)
    offer_item_label = Storage.edge_label!(Offer, :cart_items)

    products = [
      product_fixture(
        "product-1",
        "Merino Hoodie / Crimson",
        "Warm technical hoodie",
        "https://example.com/hoodie-crimson.png"
      ),
      product_fixture(
        "product-2",
        "Merino Hoodie / Indigo",
        "Warm technical hoodie",
        "https://example.com/hoodie-indigo.png"
      ),
      product_fixture(
        "product-3",
        "Merino Hoodie / Graphite",
        "Warm technical hoodie",
        "https://example.com/hoodie-graphite.png"
      ),
      product_fixture(
        "product-4",
        "Trail Socks / Pine",
        "Breathable socks",
        "https://example.com/socks-pine.png"
      )
    ]

    offers = [
      offer_fixture("offer-1", "product-1", "Northstar Supply", 12_500, 10, Enum.at(products, 0)),
      offer_fixture("offer-2", "product-2", "Vector Market", 13_100, 8, Enum.at(products, 1)),
      offer_fixture("offer-3", "product-3", "Northstar Supply", 11_900, 12, Enum.at(products, 2)),
      offer_fixture("offer-4", "product-4", "Canyon Goods", 2_500, 40, Enum.at(products, 3))
    ]

    cart_storage_id = Storage.uuidv7()

    cart = %{
      storage_id: cart_storage_id,
      row: Storage.node_row(Cart, %{id: "cart-1", status: "active"}, cart_storage_id)
    }

    items = [
      cart_item_fixture("item-1", 2, 12_500, Enum.at(offers, 0)),
      cart_item_fixture("item-2", 1, 13_100, Enum.at(offers, 1)),
      cart_item_fixture("item-3", 3, 2_500, Enum.at(offers, 3))
    ]

    Storage.insert_nodes!(
      Enum.map(products, & &1.row) ++
        Enum.map(offers, & &1.row) ++ [cart.row | Enum.map(items, & &1.row)]
    )

    Storage.insert_edges!(
      Enum.map(offers, fn offer ->
        Storage.edge_row(product_offer_label, offer.product_storage_id, offer.storage_id)
      end) ++
        Enum.flat_map(items, fn item ->
          [
            Storage.edge_row(cart_item_label, cart.storage_id, item.storage_id),
            Storage.edge_row(offer_item_label, item.offer_storage_id, item.storage_id)
          ]
        end)
    )
  end

  defp product_fixture(id, name, description, image) do
    storage_id = Storage.uuidv7()

    %{
      id: id,
      storage_id: storage_id,
      row:
        Storage.node_row(
          Product,
          %{
            id: id,
            name: name,
            description: description,
            images: [image]
          },
          storage_id
        )
    }
  end

  defp offer_fixture(id, product_id, offered_by, price, quantity, product) do
    storage_id = Storage.uuidv7()

    %{
      id: id,
      storage_id: storage_id,
      product_storage_id: product.storage_id,
      row:
        Storage.node_row(
          Offer,
          offer_attrs(id, product_id, offered_by, price, quantity, product),
          storage_id
        )
    }
  end

  defp cart_item_fixture(id, quantity, price_at_addition, offer) do
    storage_id = Storage.uuidv7()

    %{
      storage_id: storage_id,
      offer_storage_id: offer.storage_id,
      row:
        Storage.node_row(
          CartItem,
          %{id: id, quantity: quantity, price_at_addition: price_at_addition},
          storage_id
        )
    }
  end

  defp set_offer_quantity(offer_id, quantity) do
    Offer
    |> Ector.from()
    |> Ector.where([offer], offer.id == ^offer_id)
    |> Repo.update_all(set: [quantity: quantity])
  end

  defp offer_attrs(
         id,
         product_id,
         offered_by \\ "Northstar Supply",
         price \\ 12_500,
         quantity \\ 10,
         product \\ nil
       ) do
    %{
      id: id,
      product_id: product_id,
      offered_by: offered_by,
      price: price,
      quantity: quantity,
      product_name: product_name(product, "Merino Hoodie / Crimson"),
      product_description: product_description(product, "Warm technical hoodie")
    }
  end

  defp product_name(nil, fallback), do: fallback
  defp product_name(%{row: %{properties: %{"name" => name}}}, _fallback), do: name

  defp product_description(nil, fallback), do: fallback

  defp product_description(%{row: %{properties: %{"description" => description}}}, _fallback),
    do: description

  defp table_names do
    rows =
      case Store.adapter_name() do
        :sqlite ->
          Store.Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table'").rows

        :postgres ->
          Store.Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = current_schema()").rows
      end

    rows
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&String.starts_with?(&1, "sqlite_"))
    |> Enum.sort()
  end

  defp node_index_sql do
    rows =
      case Store.adapter_name() do
        :sqlite ->
          Store.Repo.query!(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'nodes'"
          ).rows

        :postgres ->
          Store.Repo.query!(
            "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'nodes'"
          ).rows
      end

    rows
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end
end
