// Serverer kubb-appen fra Storage med riktig content-type.
// Offentlig med vilje: filen er en statisk nettside uten hemmeligheter.
const SRC = `${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/kubb/index.html`;

let cache: { html: string; at: number } | null = null;
const TTL = 60_000;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204 });
  if (req.method !== 'GET' && req.method !== 'HEAD')
    return new Response('Method Not Allowed', { status: 405 });

  try {
    if (!cache || Date.now() - cache.at > TTL) {
      const r = await fetch(SRC, { cache: 'no-store' });
      if (!r.ok) throw new Error(`storage ${r.status}`);
      cache = { html: await r.text(), at: Date.now() };
    }
  } catch (e) {
    return new Response(`Kunne ikke hente appen: ${e}`, {
      status: 502,
      headers: { 'content-type': 'text/plain; charset=utf-8' },
    });
  }

  return new Response(req.method === 'HEAD' ? null : cache.html, {
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'public, max-age=60',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'same-origin',
    },
  });
});
