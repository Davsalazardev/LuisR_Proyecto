// catalog-service — punto de entrada (puerto 8001)
const express = require('express');
const config = require('./config');
const db = require('./db');
const cache = require('./cache');
const { router } = require('./routes');
const { HttpError, fromMongo } = require('./errors');

const app = express();
app.disable('x-powered-by');
app.set('json spaces', 2);
app.use(express.json({ limit: '100kb' }));

app.use((req, res, next) => {
  const t0 = Date.now();
  res.on('finish', () => {
    console.log(`${req.method} ${req.originalUrl} -> ${res.statusCode} ${Date.now() - t0}ms ${res.get('X-Cache') || ''}`);
  });
  next();
});

app.use(router);

app.use((req, res) => {
  res.status(404).json({ error: 'NOT_FOUND', message: `Ruta no encontrada: ${req.method} ${req.path}` });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'BAD_REQUEST', message: 'JSON mal formado.' });
  }
  const httpErr = err instanceof HttpError ? err : fromMongo(err);
  if (httpErr) {
    const payload = { error: httpErr.error, message: httpErr.message };
    if (httpErr.details !== undefined) payload.details = httpErr.details;
    return res.status(httpErr.status).json(payload);
  }
  console.error('[error]', err);
  return res.status(500).json({ error: 'INTERNAL_ERROR', message: 'Error interno del servicio.' });
});

db.connect().catch((err) => console.warn(`[mongo] conexión inicial fallida (se reintenta en cada petición): ${err.message}`));
cache.connect();

const server = app.listen(config.port, () => {
  console.log(`catalog-service escuchando en :${config.port}`);
});

function shutdown(signal) {
  console.log(`${signal} recibido, cerrando...`);
  server.close(async () => {
    await Promise.allSettled([db.client.close(), cache.client.quit()]);
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 8000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = app;
