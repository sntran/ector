defmodule StoreWeb.CheckoutLive do
  @moduledoc false

  use StoreWeb, :live_view

  alias Store.Checkout

  @impl true
  def mount(_params, session, socket) do
    cart = session_cart_id(session) |> Checkout.ensure_active_cart!()

    {:ok,
     assign(socket,
       cart_id: cart.id,
       cart_version: 0,
       summary: Checkout.get_cart_summary(cart.id),
       placed?: false
     )}
  end

  @impl true
  def handle_event("place_order", _params, socket) do
    case Checkout.process_checkout(socket.assigns.cart_id) do
      {:ok, summary} ->
        new_cart = Checkout.create_active_cart!(summary.id)
        new_summary = Checkout.get_cart_summary(new_cart.id)

        {:noreply,
         socket
         |> assign(
           cart_id: new_cart.id,
           cart_summary: new_summary,
           completed_summary: summary,
           summary: new_summary,
           placed?: true
         )
         |> update(:cart_version, &(&1 + 1))}

      {:error, :out_of_stock} ->
        {:noreply, put_flash(socket, :error, "One or more cart items are out of stock.")}

      {:error, :empty_cart} ->
        {:noreply, put_flash(socket, :error, "Your cart is empty.")}

      {:error, :not_active} ->
        {:noreply, put_flash(socket, :error, "This cart has already been processed.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="checkout-page">
      <div class="section-heading">
        <p>Checkout</p>
        <h1>Confirm your graph-backed order</h1>
      </div>

      <div class="checkout-layout">
        <form class="checkout-form" phx-submit="place_order">
          <label>
            Email <input type="email" value="ada@example.com" />
          </label>
          <label>
            Shipping address <input type="text" value="1 Analytical Engine Way" />
          </label>
          <label>
            Payment <input type="text" value="4242 4242 4242 4242" />
          </label>
          <button type="submit" disabled={@summary.items == [] or @summary.status == "converted"}>
            Complete Purchase
          </button>
          <p :if={@placed?} class="confirmation">Purchase complete.</p>
        </form>

        <aside class="checkout-summary">
          <h2>Summary</h2>
          <div :for={item <- @summary.items} class="summary-line">
            <span>{item.offer.product_name} x {item.quantity}</span>
            <strong>{Components.money(item.quantity * item.price_at_addition)}</strong>
          </div>
          <div class="summary-total">
            <span>Total</span>
            <strong>{Components.money(@summary.subtotal)}</strong>
          </div>
        </aside>
      </div>
    </section>
    """
  end

  defp session_cart_id(session) do
    Map.get(session, "cart_id", Checkout.default_cart_id())
  end
end
