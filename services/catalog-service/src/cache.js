// Redis caché (patrón cache-aside) con degradación controlada:
// cualquier fallo o lentitud (> REDIS_CACHE_TIMEOUT_MS) se trata como "sin caché"
// y la petición continúa contra MongoDB (X-Cache: BYPASS).
const crypto = require('crypto');
const { createClient } = require('redis');
const config = require('./config');

const client = createClient({
  socket: {
    host: config.redis.host,
    port: config.redis.port,
    connectTimeout: config.redis.timeoutMs,
    reconnectStrategy: (retries) => Math.min(retries * 200, 5000),
  },
  password: config.redis.password,
  disableOfflineQueue: true, // si Redis está caído, fallar al instante en vez de encolar
});

let lastErrorLogAt = 0;
client.on('error', (err) => {
  if (Date.now() - lastErrorLogAt > 30000) {
    console.warn(`[cache] Redis no disponible: ${err.message}`);
    lastErrorLogAt = Date.now();
  }
});

function withTimeout(promise) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('redis timeout')), config.redis.timeoutMs);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function safe(op) {
  if (!client.isReady) return { ok: false };
  try {
    return { ok: true, value: await withTimeout(op()) };
  } catch (err) {
    console.warn(`[cache] operación omitida: ${err.message}`);
    return { ok: false };
  }
}

const keys = {
  product: (id) => `catalog:product:${id}`,
  version: 'catalog:version',
  list: (ver, hash) => `catalog:list:v${ver}:${hash}`,
  reviews: (id, page, limit) => `catalog:reviews:${id}:p${page}:l${limit}`,
  reviewsPattern: (id) => `catalog:reviews:${id}:p*`,
};

module.exports = {
  client,
  keys,
  async connect() {
    client.connect().catch((err) => console.warn(`[cache] conexión inicial fallida: ${err.message}`));
  },
  isReady: () => client.isReady,
  async ping() {
    const r = await safe(() => client.ping());
    return r.ok && r.value === 'PONG';
  },
  /** Devuelve { status: 'HIT'|'MISS'|'BYPASS', value } */
  async getJSON(key) {
    const r = await safe(() => client.get(key));
    if (!r.ok) return { status: 'BYPASS' };
    if (r.value == null) return { status: 'MISS' };
    return { status: 'HIT', value: JSON.parse(r.value) };
  },
  async setJSON(key, value, ttlSeconds) {
    await safe(() => client.setEx(key, ttlSeconds, JSON.stringify(value)));
  },
  async listVersion() {
    const r = await safe(() => client.get(keys.version));
    if (!r.ok) return null;
    return r.value || '1';
  },
  hashFilters(obj) {
    return crypto.createHash('sha1').update(JSON.stringify(obj)).digest('hex').slice(0, 16);
  },
  /** Invalida el detalle del producto y todos los listados (INCR catalog:version). */
  async invalidateProduct(productoId) {
    await safe(() => client.multi().del(keys.product(productoId)).incr(keys.version).exec());
  },
  async invalidateReviews(productoId) {
    await safe(async () => {
      const toDelete = [];
      for await (const k of client.scanIterator({ MATCH: keys.reviewsPattern(productoId), COUNT: 100 })) {
        toDelete.push(...(Array.isArray(k) ? k : [k]));
      }
      if (toDelete.length) await client.del(toDelete);
    });
  },
};
