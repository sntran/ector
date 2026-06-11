defmodule StoreWeb.CartLive do
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
       summary: Checkout.get_cart_summary(cart.id)
     )}
  end

  @impl true
  def handle_event("update_quantity", %{"item_id" => item_id, "quantity" => quantity}, socket) do
    case parse_quantity(quantity) do
      {:ok, quantity} ->
        if current_quantity(socket, item_id) == quantity do
          {:noreply, socket}
        else
          {:noreply,
           refresh_cart(
             socket,
             Checkout.update_cart_item_quantity(socket.assigns.cart_id, item_id, quantity)
           )}
        end

      :ignore ->
        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, "Quantity must be at least 1")}
    end
  end

  def handle_event("increment_item", %{"id" => item_id}, socket) do
    {:noreply, step_item(socket, item_id, 1)}
  end

  def handle_event("decrement_item", %{"id" => item_id}, socket) do
    {:noreply, step_item(socket, item_id, -1)}
  end

  def handle_event("remove_item", %{"id" => item_id}, socket) do
    summary = Checkout.remove_cart_item(socket.assigns.cart_id, item_id)

    {:noreply,
     socket
     |> refresh_cart(summary)
     |> put_flash(:info, "Removed from cart")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="cart-page">
      <div class="section-heading">
        <p>Cart</p>
        <h1>{@summary.quantity_total} items ready for checkout</h1>
      </div>

      <div class="cart-layout">
        <div class="cart-lines">
          <article :for={item <- @summary.items} class="cart-line">
            <img src={List.first(item.product.images)} alt="" />
            <div class="cart-line-copy">
              <strong>{item.offer.product_name}</strong>
              <span>{item.offer.offered_by}</span>
            </div>
            <div class="cart-line-controls">
              <form
                id={"cart-quantity-#{item.item_id}"}
                class="quantity-form"
                phx-change="update_quantity"
                phx-submit="update_quantity"
              >
                <input type="hidden" name="item_id" value={item.item_id} />
                <button
                  type="button"
                  class="quantity-step"
                  phx-click="decrement_item"
                  phx-value-id={item.item_id}
                  disabled={item.quantity <= 1}
                >
                  -
                </button>
                <input type="number" min="1" name="quantity" value={item.quantity} />
                <button
                  type="button"
                  class="quantity-step"
                  phx-click="increment_item"
                  phx-value-id={item.item_id}
                >
                  +
                </button>
              </form>
              <span class="cart-line-unit">{Components.money(item.price_at_addition)} each</span>
              <strong class="cart-line-total">
                {Components.money(item.quantity * item.price_at_addition)}
              </strong>
              <button
                type="button"
                class="remove-line"
                phx-click="remove_item"
                phx-value-id={item.item_id}
              >
                Remove
              </button>
            </div>
          </article>

          <div :if={@summary.items == []} class="empty-state">
            Your cart is empty.
          </div>
        </div>

        <aside class="cart-summary">
          <span>Subtotal</span>
          <strong>{Components.money(@summary.subtotal)}</strong>
          <a href="/checkout">Checkout</a>
        </aside>
      </div>
    </section>
    """
  end

  defp step_item(socket, item_id, delta) do
    case Enum.find(socket.assigns.summary.items, &(&1.item_id == item_id)) do
      nil ->
        socket

      %{quantity: quantity} when quantity + delta > 0 ->
        summary =
          Checkout.update_cart_item_quantity(socket.assigns.cart_id, item_id, quantity + delta)

        refresh_cart(socket, summary)

      _item ->
        socket
    end
  end

  defp current_quantity(socket, item_id) do
    case Enum.find(socket.assigns.summary.items, &(&1.item_id == item_id)) do
      nil -> nil
      item -> item.quantity
    end
  end

  defp refresh_cart(socket, nil), do: socket

  defp refresh_cart(socket, summary) do
    socket
    |> assign(summary: summary)
    |> update(:cart_version, &(&1 + 1))
  end

  defp parse_quantity(""), do: :ignore

  defp parse_quantity(quantity) when is_binary(quantity) do
    case Integer.parse(quantity) do
      {quantity, ""} when quantity > 0 -> {:ok, quantity}
      _other -> :error
    end
  end

  defp parse_quantity(_quantity), do: :error

  defp session_cart_id(session) do
    Map.get(session, "cart_id", Checkout.default_cart_id())
  end
end
