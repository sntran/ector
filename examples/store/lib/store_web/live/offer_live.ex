defmodule StoreWeb.OfferLive do
  @moduledoc false

  use StoreWeb, :live_view

  alias Store.{Catalog, Checkout}

  @impl true
  def mount(_params, session, socket) do
    cart = session_cart_id(session) |> Checkout.ensure_active_cart!()

    {:ok,
     assign(socket,
       cart_id: cart.id,
       cart_version: 0,
       cart_summary: Checkout.get_cart_summary(cart.id)
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, assign(socket, offer: Catalog.get_offer_details(id))}
  end

  @impl true
  def handle_event("add_item", %{"id" => offer_id}, socket) do
    summary = Checkout.add_offer_to_cart(socket.assigns.cart_id, offer_id)

    {:noreply,
     socket
     |> assign(cart_id: summary.id, cart_summary: summary)
     |> update(:cart_version, &(&1 + 1))
     |> put_flash(:info, "Added to cart")}
  end

  @impl true
  def render(%{offer: nil} = assigns) do
    ~H"""
    <section class="detail-empty">
      <h1>Offer not found</h1>
      <a href="/">Back to catalog</a>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class="detail-layout">
      <div class="detail-image">
        <img src={List.first(@offer.images)} alt={@offer.product_name} />
      </div>

      <div class="detail-copy">
        <a href="/" class="back-link">Catalog</a>
        <h1>{@offer.product_name}</h1>
        <p>{@offer.product_description}</p>

        <dl>
          <div>
            <dt>Vendor</dt>
            <dd>{@offer.offered_by}</dd>
          </div>
          <div>
            <dt>Available</dt>
            <dd>{@offer.quantity}</dd>
          </div>
          <div>
            <dt>Price</dt>
            <dd>{Components.money(@offer.price)}</dd>
          </div>
        </dl>

        <button type="button" phx-click="add_item" phx-value-id={@offer.id}>Add to cart</button>
      </div>
    </section>
    """
  end

  defp session_cart_id(session) do
    Map.get(session, "cart_id", Checkout.default_cart_id())
  end
end
