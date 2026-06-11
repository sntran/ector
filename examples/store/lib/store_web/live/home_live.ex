defmodule StoreWeb.HomeLive do
  @moduledoc false

  use StoreWeb, :live_view

  alias Store.{Catalog, Checkout}

  @page_size Application.compile_env(:store, :catalog_page_size, 24)

  @impl true
  def mount(_params, session, socket) do
    cart = session_cart_id(session) |> Checkout.ensure_active_cart!()

    {:ok,
     socket
     |> stream_configure(:offers, dom_id: &"offer-#{&1.id}")
     |> assign(
       cart_id: cart.id,
       cart_version: 0,
       cart_summary: Checkout.get_cart_summary(cart.id),
       filters: %{"q" => "", "offered_by" => "", "sort" => "newest"},
       page_params: %{},
       next_cursor: nil,
       previous_cursor: nil,
       visible_offer_count: 0,
       has_offers?: false,
       hero_image: nil,
       loaded_url_state: nil,
       vendors: Catalog.list_vendors()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "q" => Map.get(params, "q", ""),
      "offered_by" => Map.get(params, "offered_by", ""),
      "sort" => Map.get(params, "sort", "newest")
    }

    page_params = pagination_params(params)
    url_state = url_state(filters, page_params)

    if socket.assigns.loaded_url_state == url_state do
      {:noreply, socket}
    else
      page =
        filters
        |> page_opts(page_params)
        |> Catalog.list_offer_cards_page()

      {:noreply,
       socket
       |> assign_page(filters, page_params, page)
       |> stream(:offers, page.entries, reset: true)}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: catalog_path(filters))}
  end

  def handle_event("add_item", %{"id" => offer_id}, socket) do
    summary = Checkout.add_offer_to_cart(socket.assigns.cart_id, offer_id)

    {:noreply,
     socket
     |> assign(cart_id: summary.id, cart_summary: summary)
     |> update(:cart_version, &(&1 + 1))
     |> put_flash(:info, "Added to cart")}
  end

  def handle_event("load_next", _params, %{assigns: %{next_cursor: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("load_next", _params, socket) do
    cursor = socket.assigns.next_cursor
    page_params = %{"cursor" => cursor}

    page =
      socket.assigns.filters
      |> page_opts(page_params)
      |> Catalog.list_offer_cards_page()

    {:noreply,
     socket
     |> assign_scrolled_page(:next, page_params, page)
     |> stream(:offers, page.entries)
     |> push_patch(to: catalog_path(socket.assigns.filters, page_params), replace: true)}
  end

  def handle_event("load_previous", _params, %{assigns: %{previous_cursor: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("load_previous", _params, socket) do
    cursor = socket.assigns.previous_cursor
    page_params = %{"cursor" => cursor}

    page =
      socket.assigns.filters
      |> page_opts(page_params)
      |> Catalog.list_offer_cards_page()

    {:noreply,
     socket
     |> assign_scrolled_page(:previous, page_params, page)
     |> stream(:offers, Enum.reverse(page.entries), at: 0)
     |> push_patch(to: catalog_path(socket.assigns.filters, page_params), replace: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="hero">
      <div class="hero-copy">
        <p>Zero-migration storefront</p>
        <h1>Commerce over a graph-shaped catalog.</h1>
        <span>
          Browse offers backed by Ector nodes, edge joins, denormalized search text, and
          JSON expression indexes.
        </span>
        <div class="hero-actions">
          <a href="#catalog">Browse catalog</a>
          <a href="/cart">View cart</a>
        </div>
      </div>
      <div class="hero-media">
        <img :if={@hero_image} src={@hero_image} alt="" />
      </div>
    </section>

    <section id="catalog" class="catalog-toolbar">
      <form phx-change="filter" phx-submit="filter">
        <input
          type="search"
          name="filters[q]"
          value={@filters["q"]}
          placeholder="Search catalog"
          phx-debounce="250"
        />
        <select name="filters[offered_by]">
          <option value="">All vendors</option>
          <option
            :for={vendor <- @vendors}
            value={vendor}
            selected={vendor == @filters["offered_by"]}
          >
            {vendor}
          </option>
        </select>
        <select name="filters[sort]">
          <option value="newest" selected={@filters["sort"] == "newest"}>Newest</option>
          <option value="price_asc" selected={@filters["sort"] == "price_asc"}>
            Price low to high
          </option>
          <option value="price_desc" selected={@filters["sort"] == "price_desc"}>
            Price high to low
          </option>
        </select>
      </form>
    </section>

    <section
      :if={@has_offers?}
      id="offers"
      class="product-grid"
      phx-update="stream"
      phx-viewport-top="load_previous"
      phx-viewport-bottom="load_next"
    >
      <article :for={{dom_id, offer} <- @streams.offers} id={dom_id} class="product-card">
        <a href={"/offers/#{offer.id}"} class="product-image">
          <img src={List.first(offer.images)} alt={offer.product_name} />
        </a>
        <div class="product-body">
          <div>
            <a href={"/offers/#{offer.id}"} class="product-name">{offer.product_name}</a>
            <p>{Components.short(offer.product_description, 120)}</p>
          </div>
          <div class="product-meta">
            <span>{offer.offered_by}</span>
            <strong>{Components.money(offer.price)}</strong>
          </div>
          <button type="button" phx-click="add_item" phx-value-id={offer.id}>Add to cart</button>
        </div>
      </article>
    </section>

    <div :if={!@has_offers?} class="empty-state">
      No offers match the current filters.
    </div>

    <section :if={@has_offers?} class="pagination-bar">
      <span>
        Showing {@visible_offer_count} streamed offers
      </span>
      <code :if={@previous_cursor}>prev {short_cursor(@previous_cursor)}</code>
      <code :if={@next_cursor}>next {short_cursor(@next_cursor)}</code>
      <strong :if={@previous_cursor}>Scroll up for previous</strong>
      <strong :if={@next_cursor}>Scroll down for next</strong>
      <strong :if={is_nil(@next_cursor)}>End of catalog</strong>
    </section>
    """
  end

  defp catalog_path(filters, page_params \\ %{}) do
    query =
      filters
      |> Map.merge(page_params)
      |> Enum.reject(fn
        {_key, ""} -> true
        {"sort", "newest"} -> true
        {"cursor", nil} -> true
        {"cursor", ""} -> true
        _entry -> false
      end)
      |> URI.encode_query()

    if query == "", do: "/", else: "/?#{query}"
  end

  defp pagination_params(%{"cursor" => cursor}) when cursor not in [nil, ""] do
    %{"cursor" => cursor}
  end

  defp pagination_params(_params), do: %{}

  defp page_opts(filters, page_params) do
    [
      q: filters["q"],
      offered_by: filters["offered_by"],
      sort: filters["sort"],
      limit: @page_size
    ]
    |> Keyword.merge(page_cursor_opts(page_params))
  end

  defp page_cursor_opts(%{"cursor" => cursor}), do: [cursor: cursor]
  defp page_cursor_opts(_page_params), do: []

  defp assign_page(socket, filters, page_params, page) do
    assign(socket,
      filters: filters,
      page_params: page_params,
      next_cursor: page.next_cursor,
      previous_cursor: page.previous_cursor,
      visible_offer_count: length(page.entries),
      has_offers?: page.entries != [],
      hero_image: hero_image(page.entries),
      loaded_url_state: url_state(filters, page_params),
      vendors: Catalog.list_vendors()
    )
  end

  defp assign_scrolled_page(socket, direction, page_params, page) do
    socket
    |> assign(
      page_params: page_params,
      loaded_url_state: url_state(socket.assigns.filters, page_params),
      has_offers?: socket.assigns.has_offers? or page.entries != [],
      visible_offer_count: socket.assigns.visible_offer_count + length(page.entries),
      hero_image: scrolled_hero_image(direction, socket.assigns.hero_image, page.entries)
    )
    |> assign_scroll_cursors(direction, page)
  end

  defp assign_scroll_cursors(socket, :next, page) do
    assign(socket, next_cursor: page.next_cursor)
  end

  defp assign_scroll_cursors(socket, :previous, page) do
    assign(socket, previous_cursor: page.previous_cursor)
  end

  defp scrolled_hero_image(:previous, _current_image, entries), do: hero_image(entries)
  defp scrolled_hero_image(:next, nil, entries), do: hero_image(entries)
  defp scrolled_hero_image(:next, current_image, _entries), do: current_image

  defp hero_image([]), do: nil
  defp hero_image([offer | _offers]), do: List.first(offer.images)

  defp url_state(filters, page_params) do
    %{filters: filters, page: page_params}
  end

  defp short_cursor(cursor) when is_binary(cursor) and byte_size(cursor) > 18 do
    "#{String.slice(cursor, 0, 10)}...#{String.slice(cursor, -6, 6)}"
  end

  defp short_cursor(cursor), do: cursor

  defp session_cart_id(session) do
    Map.get(session, "cart_id", Checkout.default_cart_id())
  end
end
