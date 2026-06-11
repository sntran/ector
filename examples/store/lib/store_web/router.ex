defmodule StoreWeb.Router do
  use StoreWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {StoreWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", StoreWeb do
    pipe_through(:browser)

    live("/", HomeLive, :index)
    live("/offers/:id", OfferLive, :show)
    live("/cart", CartLive, :show)
    live("/checkout", CheckoutLive, :show)
  end
end
