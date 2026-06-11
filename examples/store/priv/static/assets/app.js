import { Socket } from "/deps/phoenix/phoenix.mjs"
import { LiveSocket } from "/deps/phoenix_live_view/phoenix_live_view.esm.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken } })

liveSocket.connect()
window.liveSocket = liveSocket
