Mix.Task.run("app.start")

alias Store.Catalog
alias Store.Ector, as: EctorStore
alias Store.Relational, as: RelationalStore

n = String.to_integer(System.get_env("BENCH_N") || "500")
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
  print: [fast_warning: false]
]

IO.puts("== Store benchmark: #{adapter} adapter, #{n} synthetic products ==")

IO.puts(
  "Run again with STORE_ADAPTER=postgres and STORE_DATABASE_URL=... to collect PostgreSQL results."
)

product_attrs = fn i ->
  %{
    id: "bench-p#{i}",
    sku: "BENCH-#{i}",
    name: "Bench Product #{i}",
    category: Enum.at(~w(books office tools), rem(i, 3)),
    price: i / 10,
    status: if(rem(i, 5) == 0, do: "archived", else: "active")
  }
end

seed_relational_products = fn ->
  Enum.each(1..n, fn i ->
    {:ok, _product} =
      Store.RelationalRepo.insert(
        RelationalStore.Product.changeset(%RelationalStore.Product{}, product_attrs.(i))
      )
  end)
end

seed_ector_products = fn ->
  Enum.each(1..n, fn i ->
    {:ok, _product} =
      Store.EctorRepo.insert(
        EctorStore.Product.changeset(%EctorStore.Product{}, product_attrs.(i))
      )
  end)
end

Benchee.run(
  %{
    "insert products (relational)" =>
      {fn _input -> seed_relational_products.() end,
       before_each: fn _input ->
         Store.Sandbox.reset!()
         :ok
       end},
    "insert products (ector graph)" =>
      {fn _input -> seed_ector_products.() end,
       before_each: fn _input ->
         Store.Sandbox.reset!()
         :ok
       end}
  },
  bench_opts
)

query_setup = fn _input ->
  Store.Sandbox.reset!()
  seed_relational_products.()
  seed_ector_products.()
  :ok
end

Benchee.run(
  %{
    "complex filter (relational b-tree)" =>
      {fn _input -> Catalog.active_book_names_relational(Store.RelationalRepo) end,
       before_each: query_setup},
    "complex filter (ector partial json index)" =>
      {fn _input -> Catalog.active_book_names_ector(Store.EctorRepo) end,
       before_each: query_setup}
  },
  bench_opts
)

association_setup = fn _input ->
  Store.Sandbox.reset!()
  Catalog.seed_relational_cart(Store.RelationalRepo)
  {:ok, _customer} = Catalog.seed_ector_cart(Store.EctorRepo)
  :ok
end

Benchee.run(
  %{
    "association load (relational preload)" =>
      {fn _input -> Catalog.load_relational_cart(Store.RelationalRepo) end,
       before_each: association_setup},
    "association load (ector graph join)" =>
      {fn _input -> Catalog.load_ector_cart_items(Store.EctorRepo) end,
       before_each: association_setup}
  },
  bench_opts
)

Benchee.run(
  %{
    "filtered bulk update (relational column)" =>
      {fn _input -> Catalog.archive_active_books_relational(Store.RelationalRepo) end,
       before_each: query_setup},
    "filtered bulk update (ector json mutation)" =>
      {fn _input -> Catalog.archive_active_books_ector(Store.EctorRepo) end,
       before_each: query_setup}
  },
  bench_opts
)

Store.Sandbox.drop!()
