Mix.Task.run("app.start")

alias Store.Catalog.{Offer, Product}
alias Store.Checkout.{Cart, CartItem}
alias Store.Storage

endpoint = "https://fakestoreapi.com/products"
vendors = ["Northstar Supply", "Vector Market", "Canyon Goods", "Brightline Co."]
sizes = ~w(XS S M L XL XXL)

colors = [
  "Crimson",
  "Indigo",
  "Pine",
  "Ivory",
  "Graphite",
  "Copper",
  "Ocean",
  "Marigold",
  "Violet",
  "Slate"
]

Store.Sandbox.migrate!()
Storage.delete_all!()

products =
  case System.cmd("curl", ["-L", "--fail", "--silent", "--show-error", endpoint],
         stderr_to_stdout: true
       ) do
    {body, 0} ->
      JSON.decode!(body)

    {output, status} ->
      raise "Fake Store API request failed with exit #{status}: #{output}"
  end

variations =
  for product <- products,
      size <- sizes,
      color <- colors do
    %{
      source_id: Map.fetch!(product, "id"),
      title: "#{Map.fetch!(product, "title")} / #{size} / #{color}",
      description: Map.fetch!(product, "description"),
      image: Map.fetch!(product, "image"),
      price: Map.fetch!(product, "price"),
      size: size,
      color: color
    }
  end

if length(variations) < 1_000 do
  raise "expected at least 1,000 synthesized products, got #{length(variations)}"
end

product_offer_pairs =
  variations
  |> Enum.with_index()
  |> Enum.map(fn {variation, index} ->
    product_storage_id = Storage.uuidv7()
    offer_storage_id = Storage.uuidv7()
    product_id = Storage.uuidv7()
    offer_id = Storage.uuidv7()
    offered_by = Enum.at(vendors, rem(index, length(vendors)))
    price = round(variation.price * 100)

    product_properties = %{
      id: product_id,
      name: variation.title,
      description: variation.description,
      images: [variation.image]
    }

    offer_properties = %{
      id: offer_id,
      product_id: product_id,
      offered_by: offered_by,
      price: price,
      quantity: 25 + rem(index, 175),
      product_name: variation.title,
      product_description: variation.description
    }

    %{
      product_storage_id: product_storage_id,
      offer_storage_id: offer_storage_id,
      product: Storage.node_row(Product, product_properties, product_storage_id),
      offer: Storage.node_row(Offer, offer_properties, offer_storage_id)
    }
  end)

product_offer_label = Storage.edge_label!(Product, :offers)
cart_item_label = Storage.edge_label!(Cart, :items)
offer_cart_item_label = Storage.edge_label!(Offer, :cart_items)

product_offer_edges =
  Enum.map(product_offer_pairs, fn pair ->
    Storage.edge_row(product_offer_label, pair.product_storage_id, pair.offer_storage_id)
  end)

selected_offers = Enum.take(product_offer_pairs, 3)
cart_storage_id = Storage.uuidv7()
cart_id = Store.Checkout.default_cart_id()

cart_node =
  Storage.node_row(
    Cart,
    %{
      id: cart_id,
      status: "active"
    },
    cart_storage_id
  )

cart_items =
  selected_offers
  |> Enum.with_index(1)
  |> Enum.map(fn {pair, quantity} ->
    offer_price = pair.offer.properties["price"]
    item_storage_id = Storage.uuidv7()

    %{
      storage_id: item_storage_id,
      offer_storage_id: pair.offer_storage_id,
      row:
        Storage.node_row(
          CartItem,
          %{
            id: Storage.uuidv7(),
            cart_id: cart_storage_id,
            offer_id: pair.offer_storage_id,
            quantity: quantity,
            price_at_addition: offer_price
          },
          item_storage_id
        )
    }
  end)

node_rows =
  Enum.flat_map(product_offer_pairs, &[&1.product, &1.offer]) ++
    [cart_node] ++ Enum.map(cart_items, & &1.row)

cart_item_edges =
  Enum.flat_map(cart_items, fn item ->
    [
      Storage.edge_row(cart_item_label, cart_storage_id, item.storage_id),
      Storage.edge_row(offer_cart_item_label, item.offer_storage_id, item.storage_id)
    ]
  end)

edge_rows = product_offer_edges ++ cart_item_edges

node_count = Storage.insert_nodes!(node_rows)
edge_count = Storage.insert_edges!(edge_rows)

IO.puts("""
Seeded #{node_count} nodes and #{edge_count} edges.
Products: #{length(product_offer_pairs)}
Offers: #{length(product_offer_pairs)}
Active cart id: #{cart_id}
""")
