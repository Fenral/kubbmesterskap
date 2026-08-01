self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

self.addEventListener('push', event => {
  let data = {};
  try { data = event.data?.json() || {}; } catch(_) { data = { body:event.data?.text() || '' }; }
  event.waitUntil(self.registration.showNotification(data.title || 'Kilkasting2026', {
    body:data.body || 'Turneringen er oppdatert.',
    tag:data.tag || 'kilkast',
    renotify:true,
    requireInteraction:true,
    vibrate:[300,150,300,150,600],
    data:{ url:data.url || '/' }
  }));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type:'window', includeUncontrolled:true });
    const existing = windows.find(client => client.url.startsWith(self.location.origin));
    if(existing){ await existing.focus(); existing.navigate(url); return; }
    await self.clients.openWindow(url);
  })());
});
