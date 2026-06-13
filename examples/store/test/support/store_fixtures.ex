defmodule Store.Fixtures do
  @moduledoc false

  alias Store.Catalog.{Offer, Product}
  alias Store.Checkout
  alias Store.Checkout.{Cart, CartItem}
  alias Store.Storage

  def seed_storefront_fixture! do
    product_offer_label = Storage.edge_label!(Product, :offers)
    cart_item_label = Storage.edge_label!(Cart, :items)
    offer_cart_item_label = Storage.edge_label!(Offer, :cart_items)

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
      row:
        Storage.node_row(
          Cart,
          %{id: Checkout.default_cart_id(), status: "active"},
          cart_storage_id
        )
    }

    items = [
      cart_item_fixture("item-1", 2, 12_500, cart.storage_id, Enum.at(offers, 0)),
      cart_item_fixture("item-2", 1, 13_100, cart.storage_id, Enum.at(offers, 1)),
      cart_item_fixture("item-3", 3, 2_500, cart.storage_id, Enum.at(offers, 3))
    ]

    Storage.insert_nodes!(
      Enum.map(products, & &1.row) ++
        Enum.map(offers, & &1.row) ++ [cart.row] ++ Enum.map(items, & &1.row)
    )

    Storage.insert_edges!(
      Enum.map(offers, fn offer ->
        Storage.edge_row(product_offer_label, offer.product_storage_id, offer.storage_id)
      end) ++
        Enum.map(items, fn item ->
          Storage.edge_row(cart_item_label, item.cart_storage_id, item.storage_id)
        end) ++
        Enum.map(items, fn item ->
          Storage.edge_row(offer_cart_item_label, item.offer_storage_id, item.storage_id)
        end)
    )

    :ok
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
          %{
            id: id,
            product_id: product_id,
            offered_by: offered_by,
            price: price,
            quantity: quantity,
            product_name: product.row.properties["name"],
            product_description: product.row.properties["description"]
          },
          storage_id
        )
    }
  end

  defp cart_item_fixture(id, quantity, price_at_addition, cart_storage_id, offer) do
    storage_id = Storage.uuidv7()

    properties = %{
      id: id,
      cart_id: cart_storage_id,
      offer_id: offer.storage_id,
      quantity: quantity,
      price_at_addition: price_at_addition
    }

    %{
      storage_id: storage_id,
      cart_storage_id: cart_storage_id,
      offer_storage_id: offer.storage_id,
      row: Storage.node_row(CartItem, properties, storage_id)
    }
  end
end
