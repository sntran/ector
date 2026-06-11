defmodule StoreWebLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Store.{Catalog, Checkout}
  alias Store.Catalog.Offer
  alias Store.Repo

  @endpoint StoreWeb.Endpoint

  require Ector

  setup do
    Store.Sandbox.reset!()
    Store.Fixtures.seed_storefront_fixture!()

    on_exit(fn -> Store.Sandbox.drop!() end)

    {:ok, conn: build_conn()}
  end

  test "home page browses, filters, searches, and adds to cart", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Graph-native catalog"
    assert html =~ "Trail Socks / Pine"

    assert render_change(element(view, ".header-search form"), %{q: "socks"}) =~
             "Trail Socks / Pine"

    {:ok, _filtered, html} =
      live(conn, "/?q=hoodie&offered_by=Vector%20Market&sort=price_asc")

    assert html =~ "Merino Hoodie / Indigo"
    refute html =~ "Merino Hoodie / Crimson"

    render_click(element(view, "button[phx-value-id='offer-3']"))
    render_click(element(view, "button[phx-value-id='offer-2']"))

    assert Checkout.get_cart_summary(Checkout.default_cart_id()).quantity_total == 8

    html = render_click(element(view, ".cart-button"))

    assert html =~ ~s(<span class="cart-count">8</span>)
    assert html |> mini_cart_item_count() == 4
    assert html =~ "2 x $131.00"
  end

  test "home page streams the next cursor page from the viewport bottom", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="offers")
    assert html =~ ~s(phx-update="stream")
    assert html =~ ~s(phx-viewport-bottom="load_next")
    assert html =~ ~s(phx-viewport-top="load_previous")
    assert html =~ "Showing 3 streamed offers"
    assert html =~ "Scroll down for next"
    refute html =~ "Merino Hoodie / Crimson"

    html = render_hook(element(view, "#offers"), :load_next, %{"id" => "offer-offer-2"})
    path = assert_patch(view)

    assert path =~ "/?cursor="
    refute path =~ "after="
    refute path =~ "before="
    assert html =~ "Showing 4 streamed offers"
    assert html =~ "Trail Socks / Pine"
    assert html =~ "Merino Hoodie / Crimson"
    assert html =~ "End of catalog"
  end

  test "home page streams the previous cursor page from a bookmarked page", %{conn: conn} do
    first_page = Catalog.list_offer_cards_page(limit: 3)

    {:ok, view, html} = live(conn, "/?cursor=#{first_page.next_cursor}")

    assert html =~ "Merino Hoodie / Crimson"
    refute html =~ "Trail Socks / Pine"
    assert html =~ "Scroll up for previous"

    html = render_hook(element(view, "#offers"), :load_previous, %{"id" => "offer-offer-1"})
    path = assert_patch(view)

    assert path =~ "/?cursor="
    refute path =~ "after="
    refute path =~ "before="
    assert html =~ "Trail Socks / Pine"
    assert html =~ "Merino Hoodie / Crimson"
    assert html =~ "Showing 4 streamed offers"
  end

  test "home page price sorting affects the initial catalog slice", %{conn: conn} do
    {:ok, view, html} = live(conn, "/?sort=price_asc")

    assert html =~ "Trail Socks / Pine"
    assert html =~ "Merino Hoodie / Graphite"
    assert html =~ "Merino Hoodie / Crimson"
    refute html =~ "Merino Hoodie / Indigo"

    assert render_change(element(view, ".catalog-toolbar form"), %{
             "filters" => %{"q" => "", "offered_by" => "", "sort" => "newest"}
           })
  end

  test "offer detail page can add the viewed item", %{conn: conn} do
    {:ok, view, html} = live(conn, "/offers/offer-1")

    assert html =~ "Merino Hoodie / Crimson"
    assert html =~ "https://example.com/hoodie-crimson.png"

    render_click(element(view, "button", "Add to cart"))

    assert Checkout.get_cart_summary(Checkout.default_cart_id()).quantity_total == 7
  end

  test "cart and checkout pages render the active cart and convert it", %{conn: conn} do
    {:ok, cart_view, cart_html} = live(conn, "/cart")

    assert cart_html =~ "6 items ready for checkout"
    assert cart_html =~ "$456.00"
    assert cart_html =~ ~s(<span class="cart-count">6</span>)

    html =
      render_change(element(cart_view, "#cart-quantity-item-1"), %{
        "item_id" => "item-1",
        "quantity" => "4"
      })

    assert html =~ "8 items ready for checkout"
    assert html =~ "$706.00"
    assert html =~ ~s(<span class="cart-count">8</span>)
    assert Checkout.get_cart_summary(Checkout.default_cart_id()).quantity_total == 8

    html =
      render_click(element(cart_view, "button[phx-click='remove_item'][phx-value-id='item-3']"))

    assert html =~ "5 items ready for checkout"
    assert html =~ "$631.00"
    assert html =~ ~s(<span class="cart-count">5</span>)
    assert Checkout.get_cart_summary(Checkout.default_cart_id()).quantity_total == 5

    {:ok, checkout_view, checkout_html} = live(conn, "/checkout")

    assert checkout_html =~ "Confirm your graph-backed order"
    assert checkout_html =~ "Merino Hoodie / Crimson x 4"

    html = render_submit(element(checkout_view, ".checkout-form"))

    assert html =~ "Purchase complete."
    assert html =~ ~s(<span class="cart-count">0</span>)
    assert html =~ "$0.00"
    assert Checkout.get_cart_summary(Checkout.default_cart_id()).status == "active"
    assert Checkout.get_cart_summary(Checkout.default_cart_id()).quantity_total == 0
  end

  test "home add item refreshes mini cart items for a fresh active cart", %{conn: conn} do
    assert {:ok, %{status: "converted"}} = Checkout.process_checkout(Checkout.default_cart_id())

    {:ok, view, _html} = live(conn, "/")

    render_click(element(view, "button[phx-value-id='offer-3']"))
    html = render_click(element(view, ".cart-button"))

    assert html =~ ~s(<span class="cart-count">1</span>)
    assert html =~ ~s(class="mini-cart-item")
    refute html =~ "No items yet."

    {:ok, _cart_view, cart_html} = live(conn, "/cart")

    assert cart_html =~ "1 items ready for checkout"
    assert cart_html =~ ~s(<span class="cart-count">1</span>)

    {:ok, _checkout_view, checkout_html} = live(conn, "/checkout")

    assert checkout_html =~ ~s(<span class="cart-count">1</span>)
    assert checkout_html =~ "Merino Hoodie / Graphite x 1"
  end

  test "checkout page flashes out of stock when atomic stock decrement is guarded", %{conn: conn} do
    set_offer_quantity("offer-4", 2)

    {:ok, checkout_view, checkout_html} = live(conn, "/checkout")

    assert checkout_html =~ "Complete Purchase"

    assert render_submit(element(checkout_view, ".checkout-form")) =~
             "One or more cart items are out of stock."

    assert Checkout.get_cart_summary(Checkout.default_cart_id()).status == "active"
    assert Catalog.get_offer_stock("offer-1") == 10
    assert Catalog.get_offer_stock("offer-4") == 2
  end

  defp set_offer_quantity(offer_id, quantity) do
    Offer
    |> Ector.from()
    |> Ector.where([offer], offer.id == ^offer_id)
    |> Repo.update_all(set: [quantity: quantity])
  end

  defp mini_cart_item_count(html) do
    ~r/class="mini-cart-item"/
    |> Regex.scan(html)
    |> length()
  end
end
