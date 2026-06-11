defmodule StoreWeb.HeaderComponent do
  @moduledoc false

  use StoreWeb, :live_component

  alias Store.{Catalog, Checkout}

  @impl true
  def update(assigns, socket) do
    cart_id = assigns.cart_id || Checkout.default_cart_id()
    cart = Checkout.ensure_active_cart!(cart_id)
    summary = assigns[:cart_summary] || Checkout.get_cart_summary(cart.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:query, fn -> "" end)
     |> assign_new(:results, fn -> [] end)
     |> assign_new(:show_cart, fn -> false end)
     |> assign(cart_id: cart.id, summary: summary)}
  end

  @impl true
  def handle_event("toggle_cart", _params, socket) do
    {:noreply, update(socket, :show_cart, &(!&1))}
  end

  def handle_event("search", %{"q" => query}, socket) do
    results = Catalog.search_suggestions(query)
    {:noreply, assign(socket, query: query, results: results)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, query: "", results: [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header class="site-header">
      <a class="brand" href="/">
        <span class="brand-mark">E</span>
        <span>
          <strong>Ector Store</strong>
          <small>Graph-native catalog</small>
        </span>
      </a>

      <div class="header-search">
        <form phx-change="search" phx-target={@myself}>
          <input
            type="search"
            name="q"
            value={@query}
            placeholder="Search products"
            autocomplete="off"
            phx-debounce="250"
          />
        </form>

        <div :if={@results != []} class="search-popover">
          <a
            :for={offer <- @results}
            class="search-result"
            href={"/offers/#{offer.id}"}
            phx-click="clear_search"
            phx-target={@myself}
          >
            <span>{offer.product_name}</span>
            <strong>{Components.money(offer.price)}</strong>
          </a>
        </div>
      </div>

      <nav class="header-nav">
        <a href="/">Catalog</a>
        <a href="/cart">Cart</a>
        <a href="/checkout">Checkout</a>
      </nav>

      <div class="cart-menu">
        <button class="cart-button" type="button" phx-click="toggle_cart" phx-target={@myself}>
          <span class="cart-icon">Cart</span>
          <span class="cart-count">{cart_count(@summary)}</span>
        </button>

        <div :if={@show_cart} class="mini-cart">
          <div class="mini-cart-head">
            <strong>Cart</strong>
            <span>{Components.money(@summary.subtotal)}</span>
          </div>

          <div :if={@summary.items == []} class="empty-mini-cart">No items yet.</div>

          <div :for={item <- @summary.items} class="mini-cart-item">
            <img src={List.first(item.product.images)} alt="" />
            <div>
              <strong>{item.offer.product_name}</strong>
              <span>{item.quantity} x {Components.money(item.price_at_addition)}</span>
            </div>
          </div>

          <div class="mini-cart-actions">
            <a href="/cart">View cart</a>
            <a class="primary-link" href="/checkout">Checkout</a>
          </div>
        </div>
      </div>
    </header>
    """
  end

  defp cart_count(nil), do: 0
  defp cart_count(%{quantity_total: count}), do: count
  defp cart_count(%{item_count: count}), do: count
end
