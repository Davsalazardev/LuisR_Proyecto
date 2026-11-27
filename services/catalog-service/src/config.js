// Configuración leída de variables de entorno (ver .env.example del servicio).
function int(name, def) {
  const v = Number.parseInt(process.env[name] ?? '', 10);
  return Number.isFinite(v) ? v : def;
}

module.exports = {
  port: int('CATALOG_SERVICE_PORT', 8001),
  mongoUri: process.env.MONGO_URI || 'mongodb://127.0.0.1:27017/tienda_catalogo',
  mongoDbName: process.env.MONGO_DB_NAME || 'tienda_catalogo',
  mongoTimeoutMs: int('MONGO_TIMEOUT_MS', 3000),
  redis: {
    host: process.env.REDIS_CACHE_HOST || '127.0.0.1',
    port: int('REDIS_CACHE_PORT', 6379),
    password: process.env.REDIS_CACHE_PASSWORD || undefined,
    timeoutMs: int('REDIS_CACHE_TIMEOUT_MS', 500),
  },
  ttl: {
    product: int('CATALOG_CACHE_TTL_PRODUCT_SECONDS', 300),
    list: int('CATALOG_CACHE_TTL_LIST_SECONDS', 120),
    reviews: int('CATALOG_CACHE_TTL_REVIEWS_SECONDS', 120),
  },
  pageSizeDefault: 20,
  pageSizeMax: 50,
};
