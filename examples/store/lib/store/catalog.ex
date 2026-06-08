defmodule Store.Catalog do
  @moduledoc """
  Shared e-commerce workflows used by tests, documentation, and benchmarks.

  Every public function has a relational and an Ector variant so the showcase can
  compare business results without hiding the persistence strategy differences.
  """

  import Ecto.Query, only: [from: 2]
  import Ector, only: [from: 1, join: 3, select: 3, where: 3]

  alias Ector.Changeset, as: EctorChangeset
  alias Store.Ector, as: EctorStore
  alias Store.Relational, as: RelationalStore

  @catalog [
    %{id: "p1", sku: "SKU-SICP", name: "SICP", category: "books", status: "active", price: 9.99},
    %{
      id: "p2",
      sku: "SKU-CC",
      name: "Clean Code",
      category: "books",
      status: "active",
      price: 29.99
    },
    %{
      id: "p3",
      sku: "SKU-OLD",
      name: "Old Manual",
      category: "books",
      status: "archived",
      price: 4.99
    },
    %{
      id: "p4",
      sku: "SKU-PEN",
      name: "Gel Pen",
      category: "office",
      status: "active",
      price: 2.50
    }
  ]

  @cart_products [
    %{
      id: "prod-book",
      sku: "SKU-BOOK",
      name: "Clean Code",
      category: "books",
      status: "active",
      price: 30.0,
      quantity: 1,
      unit_price: 30.0,
      pricing: %{
        currency: "USD",
        list: 30.0,
        discounts: %{code: "NONE", amount: 0.0}
      }
    },
    %{
      id: "prod-pen",
      sku: "SKU-PEN",
      name: "Gel Pen",
      category: "office",
      status: "active",
      price: 2.5,
      quantity: 3,
      unit_price: 2.5,
      pricing: %{
        currency: "USD",
        list: 2.5,
        discounts: %{code: "BULK", amount: 0.25}
      }
    }
  ]

  @doc "Returns the product catalog used by filter and bulk-update scenarios."
  @spec catalog_attrs() :: [map()]
  def catalog_attrs, do: @catalog

  @doc "Seeds only products into the relational baseline."
  @spec seed_relational_catalog(module()) :: :ok
  def seed_relational_catalog(repo) do
    Enum.each(@catalog, fn attrs ->
      {:ok, _product} =
        repo.insert(RelationalStore.Product.changeset(%RelationalStore.Product{}, attrs))
    end)
  end

  @doc "Seeds only products into the Ector graph baseline."
  @spec seed_ector_catalog(module()) :: :ok
  def seed_ector_catalog(repo) do
    Enum.each(@catalog, fn attrs ->
      {:ok, _product} = repo.insert(EctorStore.Product.changeset(%EctorStore.Product{}, attrs))
    end)
  end

  @doc "Seeds a customer, cart, and cart items into the relational baseline."
  @spec seed_relational_cart(module()) :: :ok
  def seed_relational_cart(repo) do
    {:ok, _customer} =
      repo.insert(
        RelationalStore.Customer.changeset(%RelationalStore.Customer{}, %{
          id: "cust-1",
          email: "ada@example.com",
          name: "Ada Lovelace"
        })
      )

    {:ok, _cart} =
      repo.insert(
        RelationalStore.Cart.changeset(%RelationalStore.Cart{}, %{
          id: "cart-1",
          customer_id: "cust-1",
          status: "active",
          currency: "USD"
        })
      )

    Enum.each(@cart_products, fn attrs ->
      {:ok, _product} =
        repo.insert(
          RelationalStore.Product.changeset(%RelationalStore.Product{}, product_attrs(attrs))
        )

      {:ok, _cart_item} =
        repo.insert(
          RelationalStore.CartItem.changeset(%RelationalStore.CartItem{}, %{
            cart_id: "cart-1",
            product_id: attrs.id,
            quantity: attrs.quantity,
            unit_price: attrs.unit_price
          })
        )
    end)

    :ok
  end

  @doc "Seeds a customer -> cart -> product graph into Ector in one insert."
  @spec seed_ector_cart(module()) ::
          {:ok, Store.Ector.Customer.t()} | {:error, Ecto.Changeset.t()}
  def seed_ector_cart(repo) do
    product_edges =
      Enum.map(@cart_products, fn attrs ->
        product = EctorStore.Product.changeset(%EctorStore.Product{}, product_attrs(attrs))
        edge = %{quantity: attrs.quantity, unit_price: attrs.unit_price, pricing: attrs.pricing}
        {product, edge}
      end)

    cart =
      %EctorStore.Cart{}
      |> EctorStore.Cart.changeset(%{id: "cart-1", status: "active", currency: "USD"})
      |> EctorChangeset.put_edge(:items, product_edges)

    %EctorStore.Customer{}
    |> EctorStore.Customer.changeset(%{
      id: "cust-1",
      email: "ada@example.com",
      name: "Ada Lovelace"
    })
    |> EctorChangeset.put_edge(:carts, [{cart, %{created_via: "web"}}])
    |> repo.insert()
  end

  @doc "Returns active book product names through ordinary relational columns."
  @spec active_book_names_relational(module()) :: [String.t()]
  def active_book_names_relational(repo) do
    repo.all(
      from(p in RelationalStore.Product,
        where: p.category == "books" and p.status == "active",
        order_by: p.name,
        select: p.name
      )
    )
  end

  @doc "Returns active book product names through Ector JSON field redirection."
  @spec active_book_names_ector(module()) :: [String.t()]
  def active_book_names_ector(repo) do
    EctorStore.Product
    |> from()
    |> where([p], p.category == ^"books" and p.status == ^"active")
    |> select([p], p.name)
    |> repo.all()
    |> Enum.sort()
  end

  @doc "Fetches product names in a cart through a relational join."
  @spec cart_product_names_relational(module(), String.t()) :: [String.t()]
  def cart_product_names_relational(repo, cart_id \\ "cart-1") do
    repo.all(
      from(item in RelationalStore.CartItem,
        join: product in assoc(item, :product),
        where: item.cart_id == ^cart_id,
        order_by: product.name,
        select: product.name
      )
    )
  end

  @doc "Fetches product names in a cart through an Ector hidden edge join."
  @spec cart_product_names_ector(module(), String.t()) :: [String.t()]
  def cart_product_names_ector(repo, cart_id \\ "cart-1") do
    EctorStore.Cart
    |> from()
    |> join(:items, as: :product)
    |> where([cart], cart.id == ^cart_id)
    |> select([cart, product: product], product.name)
    |> repo.all()
    |> Enum.sort()
  end

  @doc "Archives active books in the relational baseline."
  @spec archive_active_books_relational(module()) :: {non_neg_integer(), nil | [term()]}
  def archive_active_books_relational(repo) do
    repo.update_all(
      from(p in RelationalStore.Product,
        where: p.category == "books" and p.status == "active"
      ),
      set: [status: "archived"]
    )
  end

  @doc "Archives active books in Ector through a filtered JSON update."
  @spec archive_active_books_ector(module()) :: {non_neg_integer(), nil | [term()]}
  def archive_active_books_ector(repo) do
    EctorStore.Product
    |> from()
    |> where([p], p.category == ^"books" and p.status == ^"active")
    |> repo.update_all(set: [status: "archived"])
  end

  @doc "Loads a cart and its product rows with Ecto preloads for benchmark parity."
  @spec load_relational_cart(module(), String.t()) :: Store.Relational.Cart.t()
  def load_relational_cart(repo, cart_id \\ "cart-1") do
    RelationalStore.Cart
    |> repo.get!(cart_id)
    |> repo.preload(cart_items: [:product])
  end

  @doc "Loads cart item names through the Ector graph join used in benchmarks."
  @spec load_ector_cart_items(module(), String.t()) :: [String.t()]
  def load_ector_cart_items(repo, cart_id \\ "cart-1") do
    cart_product_names_ector(repo, cart_id)
  end

  defp product_attrs(attrs) do
    Map.take(attrs, [:id, :sku, :name, :category, :price, :status])
  end
end
