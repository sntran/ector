Mix.Task.run("app.start")

alias Store.Catalog
alias Store.Catalog.{Offer, Product}
alias Store.Checkout
alias Store.Checkout.{Cart, CartItem}
alias Store.Storage

n = String.to_integer(System.get_env("BENCH_N") || "1000")
adapter = Store.adapter_name()

parse_seconds = fn env, default ->
  case Float.parse(System.get_env(env) || default) do
    {seconds, ""} -> seconds
    _other -> raise "expected #{env} to be a number of seconds"
  end
end

bench_opts = [
  warmup: parse_seconds.("BENCH_WARMUP", "1"),
  time: parse_seconds.("BENCH_TIME", "3"),
  memory_time: parse_seconds.("BENCH_MEMORY_TIME", "1"),
  print: [fast_warning: false]
]

product_offer_label = Storage.edge_label!(Product, :offers)
cart_item_label = Storage.edge_label!(Cart, :items)
offer_item_label = Storage.edge_label!(Offer, :cart_items)

build_rows = fn count ->
  product_offer_pairs =
    Enum.map(1..count, fn i ->
      product_storage_id = Storage.uuidv7()
      offer_storage_id = Storage.uuidv7()
      product_id = "bench-product-#{i}"
      product_name = "Bench Product #{i}"
      product_description = "Synthetic storefront product #{i}"

      %{
        product_storage_id: product_storage_id,
        offer_storage_id: offer_storage_id,
        product:
          Storage.node_row(
            Product,
            %{
              id: product_id,
              name: product_name,
              description: product_description,
              images: ["https://example.com/products/#{i}.png"]
            },
            product_storage_id
          ),
        offer:
          Storage.node_row(
            Offer,
            %{
              id: "bench-offer-#{i}",
              product_id: product_id,
              offered_by: Enum.at(["Northstar Supply", "Vector Market"], rem(i, 2)),
              price: 1_000 + i,
              quantity: 10 + rem(i, 50),
              product_name: product_name,
              product_description: product_description
            },
            offer_storage_id
          )
      }
    end)

  cart_storage_id = Storage.uuidv7()

  cart =
    Storage.node_row(Cart, %{id: "bench-cart", status: "active"}, cart_storage_id)

  cart_items =
    product_offer_pairs
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.map(fn {pair, i} ->
      item_storage_id = Storage.uuidv7()

      %{
        storage_id: item_storage_id,
        offer_storage_id: pair.offer_storage_id,
        row:
          Storage.node_row(
            CartItem,
            %{id: "bench-item-#{i}", quantity: i, price_at_addition: 1_000 + i},
            item_storage_id
          )
      }
    end)

  nodes =
    Enum.flat_map(product_offer_pairs, &[&1.product, &1.offer]) ++
      [cart | Enum.map(cart_items, & &1.row)]

  edges =
    Enum.map(product_offer_pairs, fn pair ->
      Storage.edge_row(product_offer_label, pair.product_storage_id, pair.offer_storage_id)
    end) ++
      Enum.flat_map(cart_items, fn item ->
        [
          Storage.edge_row(cart_item_label, cart_storage_id, item.storage_id),
          Storage.edge_row(offer_item_label, item.offer_storage_id, item.storage_id)
        ]
      end)

  {nodes, edges}
end

seed = fn count ->
  Store.Sandbox.reset!()
  {nodes, edges} = build_rows.(count)
  Storage.insert_nodes!(nodes)
  Storage.insert_edges!(edges)
  :ok
end

IO.puts("== Store benchmark: #{adapter} adapter, #{n} Ector-backed offers ==")

Benchee.run(
  %{
    "batch seed nodes and edges" =>
      {fn _input ->
         {nodes, edges} = build_rows.(n)
         Storage.insert_nodes!(nodes)
         Storage.insert_edges!(edges)
       end,
       before_each: fn _input ->
         Store.Sandbox.reset!()
         :ok
       end},
    "single-cursor catalog search" =>
      {fn cursor -> Catalog.list_offers(limit: 50, search: "product", cursor: cursor) end,
       before_each: fn _input ->
         seed.(n)
         Catalog.list_offers(limit: 50, search: "product").next_cursor
       end},
    "4-hop preload cart summary" =>
      {fn _input -> Checkout.get_cart_summary("bench-cart") end,
       before_each: fn _input -> seed.(n) end}
  },
  bench_opts
)

Store.Sandbox.drop!()
