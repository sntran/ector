defmodule StoreWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :store

  @session_options [
    store: :cookie,
    key: "_store_key",
    signing_salt: "store_session_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:store, "priv/static/assets"},
    gzip: false,
    only: ~w(app.css app.js)
  )

  plug(Plug.Static,
    at: "/deps/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.mjs)
  )

  plug(Plug.Static,
    at: "/deps/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(StoreWeb.Router)
end
