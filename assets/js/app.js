import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrf = document.querySelector('meta[name="csrf-token"]').content
// Merge Notifications into LiveSocket hooks. CSRF token is the app.js csrf.
const Notifications = {
  mounted() {
    this.status = message => {
      const status = document.getElementById("notification-status");
      if (status) status.textContent = message;
    };
    this.supported = () => {
      const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
        (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
      if (ios && !navigator.standalone && !matchMedia("(display-mode: standalone)").matches) {
        this.status("Add To to your Home Screen, then open it there to enable notifications.");
        return false;
      }
      if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
        this.status("This browser does not support notifications. On iPhone use iOS 16.4 or later.");
        return false;
      }
      if (!this.el.dataset.vapidKey) {
        this.status("Notifications need server setup before they can be enabled.");
        return false;
      }
      return true;
    };
    this.save = async subscription => {
      const response = await fetch("/api/push/subscriptions", {
        method: "POST",
        headers: {"Content-Type": "application/json", "x-csrf-token": csrf},
        body: JSON.stringify({...subscription.toJSON(), time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone})
      });
      if (!response.ok) throw new Error("Could not save notifications. Check your connection and try again.");
      this.status("Notifications enabled on this device.");
    };
    this.refresh = async () => {
      if (!this.supported() || Notification.permission !== "granted") return;
      const registration = await navigator.serviceWorker.register("/sw.js");
      const subscription = await registration.pushManager.getSubscription();
      if (subscription) await this.save(subscription);
    };
    this.click = async () => {
      if (!this.supported()) return;
      this.el.disabled = true;
      try {
        // Request permission directly in the click handler for iOS user activation.
        const permission = await Notification.requestPermission();
        if (permission !== "granted") {
          this.status("Notification permission was not granted. You can change it in your device settings.");
          return;
        }
        await navigator.serviceWorker.register("/sw.js");
        const registration = await navigator.serviceWorker.ready;
        const key = this.el.dataset.vapidKey;
        const raw = atob((key + "=".repeat((4 - key.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/"));
        const applicationServerKey = Uint8Array.from(raw, c => c.charCodeAt(0));
        const subscription = await registration.pushManager.getSubscription() ||
          await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey});
        await this.save(subscription);
      } catch (error) {
        this.status(error.message || "Could not enable notifications. Try again.");
      } finally {
        this.el.disabled = false;
      }
    };
    this.el.addEventListener("click", this.click);
    this.refresh().catch(() => this.status("Could not refresh notifications. Check your connection."));
  },
  reconnected() {
    this.refresh().catch(() => this.status("Could not refresh notifications. Check your connection."));
  },
  destroyed() { this.el.removeEventListener("click", this.click); }
};

const hooks = {
  Notifications,
  InlineTask: {
    mounted() {
      this.keydown = event => {
        if (event.key === "Enter" && !event.shiftKey && !event.isComposing &&
          event.target.matches('input:not([type="date"]), textarea')) {
          event.preventDefault()
          event.target.blur()
        }
      }
      this.click = event => {
        if (event.target.matches('input[type="date"]')) {
          try { event.target.showPicker?.() } catch (_) { /* Native picker remains available. */ }
        }
      }
      this.el.addEventListener("keydown", this.keydown)
      this.el.addEventListener("click", this.click)
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.keydown)
      this.el.removeEventListener("click", this.click)
    }
  },
  QuickEntry: {
    mounted() {
      this.keydown = event => {
        const title = document.getElementById("task-title")
        if (event.altKey && ["ArrowUp", "ArrowDown"].includes(event.key) &&
          event.target.matches('li > input[type="checkbox"]')) {
          event.preventDefault()
          const row = event.target.closest("li")
          const groups = [...new Set([...this.el.querySelectorAll("[data-drop-group]")].map(el => el.dataset.dropGroup))]
          const index = Math.max(0, Math.min(groups.length - 1,
            groups.indexOf(row.dataset.group) + (event.key === "ArrowDown" ? 1 : -1)))
          this.pushEvent("move-task", {id: row.dataset.taskId, group: groups[index]})
        } else if (event.target === title && event.key === "Enter" && event.shiftKey) {
          event.preventDefault()
          document.getElementById("task-details").open = true
          document.getElementById("task-description").focus()
        } else if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey && !event.isComposing &&
          !event.target.closest('input, textarea, select, button, summary, a, [contenteditable], dialog')) {
          title.focus()
        }
      }
      window.addEventListener("keydown", this.keydown)
      this.clearDrag = () => {
        if (!this.drag) return
        this.drag.row.classList.remove("dragging")
        this.drag.target?.classList.remove("drop-target")
        if (this.drag.grip.hasPointerCapture(this.drag.pointerId)) {
          this.drag.grip.releasePointerCapture(this.drag.pointerId)
        }
        this.drag = null
      }
      this.pointerdown = event => {
        this.skipClick = false
        if (!event.isPrimary || event.button !== 0 || !event.target.matches('li > input[type="checkbox"]')) return
        this.drag = {row: event.target.closest("li"), grip: event.target,
          pointerId: event.pointerId, x: event.clientX, y: event.clientY, active: false}
        event.target.setPointerCapture(event.pointerId)
      }
      this.pointermove = event => {
        const drag = this.drag
        if (!drag || event.pointerId !== drag.pointerId) return
        if (!drag.active && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) < 6) return
        drag.active = true
        event.preventDefault()
        drag.row.classList.add("dragging")
        const target = document.elementFromPoint(event.clientX, event.clientY)?.closest("[data-drop-group]")
        drag.target?.classList.remove("drop-target")
        drag.target = this.el.contains(target) ? target : null
        drag.target?.classList.add("drop-target")
      }
      this.pointerup = event => {
        const drag = this.drag
        if (!drag || event.pointerId !== drag.pointerId) return
        if (drag.active) {
          this.skipClick = true
          if (event.type === "pointerup" && drag.target && drag.target.dataset.dropGroup !== drag.row.dataset.group) {
            this.pushEvent("move-task", {id: drag.row.dataset.taskId, group: drag.target.dataset.dropGroup})
          }
        }
        this.clearDrag()
      }
      this.click = event => {
        if (this.skipClick && event.detail > 0) {
          event.preventDefault()
          event.stopImmediatePropagation()
          this.skipClick = false
        }
      }
      this.el.addEventListener("pointerdown", this.pointerdown)
      this.el.addEventListener("pointermove", this.pointermove)
      this.el.addEventListener("pointerup", this.pointerup)
      this.el.addEventListener("pointercancel", this.pointerup)
      this.el.addEventListener("click", this.click, true)
      this.handleEvent("task-saved", () => {
        document.getElementById("task-form").reset()
        document.getElementById("task-details").open = false
        document.getElementById("task-title").focus()
      })
      this.handleEvent("focus-group", ({name}) => {
        const input = [...document.querySelectorAll("input[data-group]")].find(input => input.dataset.group === name)
        if (input) { input.focus(); input.select() }
      })
    },
    disconnected() { document.getElementById("connection-status").hidden = false },
    reconnected() { document.getElementById("connection-status").hidden = true },
    destroyed() {
      this.clearDrag()
      window.removeEventListener("keydown", this.keydown)
      this.el.removeEventListener("pointerdown", this.pointerdown)
      this.el.removeEventListener("pointermove", this.pointermove)
      this.el.removeEventListener("pointerup", this.pointerup)
      this.el.removeEventListener("pointercancel", this.pointerup)
      this.el.removeEventListener("click", this.click, true)
    }
  },
  MergeDialog: {
    mounted() {
      this.el.showModal()
      this.el.addEventListener("cancel", event => { event.preventDefault(); this.pushEvent("cancel-merge", {}) })
    }
  }
}
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrf}, hooks})
liveSocket.connect()
window.liveSocket = liveSocket
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {})
