self.addEventListener("push", event => {
  const data = event.data ? event.data.json() : {};
  event.waitUntil(self.registration.showNotification(data.title || "To", {
    body: data.body || "",
    tag: data.tag,
    icon: "/icon-192.png",
    data: {url: data.url || "/"}
  }));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "/", self.location.origin);
  if (url.origin !== self.location.origin) return;
  event.waitUntil(self.clients.matchAll({type: "window", includeUncontrolled: true}).then(async windows => {
    for (const client of windows) {
      if ("focus" in client) {
        await client.navigate(url.href);
        return client.focus();
      }
    }
    return self.clients.openWindow(url.href);
  }));
});
