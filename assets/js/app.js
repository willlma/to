import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks} from "phoenix-colocated/to"
import "phoenix-colocated/to/colocated.css"

const csrf = document.querySelector('meta[name="csrf-token"]').content
// A full page load starts a new LiveView, so discard the previous view's history metadata.
history.replaceState(null, "")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrf}, hooks})
liveSocket.connect()
window.liveSocket = liveSocket
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {})
