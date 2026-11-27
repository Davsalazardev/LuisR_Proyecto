// Rutas del catalog-service. Nginx publica este servicio como /api/catalog/*
// (proxy_pass con "/" final), así que aquí las rutas van sin prefijo.
const express = require('express');
const { Int32, Double } = require('mongodb');
const config = require('./config');
const db = require('./db');
const cache = require('./cache');
const { badRequest, notFound } = require('./errors');

const router = express.Router();
const ah = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
const startedAt = Date.now();

// Campos que calcula el servidor: el cliente no puede enviarlos.
const SERVER_FIELDS = ['_id', 'creadoEn', 'actualizadoEn', 'resumenResenas'];
const PRODUCT_PROJECTION = { _id: 0 };

function assertObjectBody(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw badRequest('El cuerpo debe ser un objeto JSON.');
  }
  const operators = Object.keys(body).filter((k) => k.startsWith('$'));
  if (operators.length) throw badRequest('No se permiten operadores de MongoDB en el cuerpo.', { campos: operators });
}

function rejectServerFields(body, extra = []) {
  const blocked = [...SERVER_FIELDS, ...extra].filter((f) => Object.prototype.hasOwnProperty.call(body, f));
  if (blocked.length) {
    throw badRequest('Estos campos los administra el servidor y no se pueden enviar.', { campos: blocked });
  }
}

function parseNumber(value, name, { min = -Infinity, integer = false } = {}) {
  if (value === undefined || value === '') return undefined;
  const n = Number(value);
  if (!Number.isFinite(n) || n < min || (integer && !Number.isInteger(n))) {
    throw badRequest(`Parámetro '${name}' inválido.`, { valor: value });
  }
  return n;
}

function pagination(query, defLimit) {
  const page = parseNumber(query.page, 'page', { min: 1, integer: true }) ?? 1;
  const limit = parseNumber(query.limit, 'limit', { min: 1, integer: true }) ?? defLimit;
  if (limit > config.pageSizeMax) throw badRequest(`'limit' máximo es ${config.pageSizeMax}.`);
  return { page, limit, skip: (page - 1) * limit };
}

/** Lectura cache-aside: intenta Redis, si no, ejecuta loader() contra MongoDB y guarda. */
async function cacheAside(res, key, ttl, loader) {
  const hit = key ? await cache.getJSON(key) : { status: 'BYPASS' };
  if (hit.status === 'HIT') {
    res.set('X-Cache', 'HIT');
    return hit.value;
  }
  const value = await loader();
  if (value !== null && hit.status === 'MISS') await cache.setJSON(key, value, ttl);
  res.set('X-Cache', hit.status);
  return value;
}

// ---------------------------------------------------------------------------
// GET /health — estado de MongoDB (obligatorio) y Redis caché (opcional)
// ---------------------------------------------------------------------------
router.get('/health', ah(async (req, res) => {
  const t0 = Date.now();
  let mongoOk = true;
  try { await db.ping(); } catch { mongoOk = false; }
  const mongoMs = Date.now() - t0;
  const redisOk = await cache.ping();
  const status = !mongoOk ? 'down' : redisOk ? 'ok' : 'degraded';
  res.status(mongoOk ? 200 : 503).json({
    service: 'catalog-service',
    status,
    mongodb: { status: mongoOk ? 'up' : 'down', latencyMs: mongoMs },
    redisCache: { status: redisOk ? 'up' : 'down' },
    uptimeSec: Math.round((Date.now() - startedAt) / 1000),
  });
}));

// ---------------------------------------------------------------------------
// GET /products — listado con filtros categoria, precioMin, precioMax, q + paginación
// ---------------------------------------------------------------------------
router.get('/products', ah(async (req, res) => {
  const { categoria, q } = req.query;
  const precioMin = parseNumber(req.query.precioMin, 'precioMin', { min: 0 });
  const precioMax = parseNumber(req.query.precioMax, 'precioMax', { min: 0 });
  if (precioMin !== undefined && precioMax !== undefined && precioMin > precioMax) {
    throw badRequest("'precioMin' no puede ser mayor que 'precioMax'.");
  }
  if (categoria !== undefined && typeof categoria !== 'string') throw badRequest("'categoria' inválida.");
  if (q !== undefined && typeof q !== 'string') throw badRequest("'q' inválido.");
  const { page, limit, skip } = pagination(req.query, config.pageSizeDefault);

  const filter = { activo: true };
  if (categoria) filter.categoria = categoria;
  if (precioMin !== undefined || precioMax !== undefined) {
    filter.precio = {};
    if (precioMin !== undefined) filter.precio.$gte = precioMin;
    if (precioMax !== undefined) filter.precio.$lte = precioMax;
  }
  if (q) filter.$text = { $search: q };

  const filtros = { categoria: categoria || null, precioMin: precioMin ?? null, precioMax: precioMax ?? null, q: q || null };
  const ver = await cache.listVersion();
  const key = ver ? cache.keys.list(ver, cache.hashFilters({ ...filtros, page, limit })) : null;

  const body = await cacheAside(res, key, config.ttl.list, async () => {
    const [total, items] = await Promise.all([
      db.productos.countDocuments(filter),
      db.productos.find(filter, { projection: PRODUCT_PROJECTION })
        .sort({ precio: 1, productoId: 1 }).skip(skip).limit(limit).toArray(),
    ]);
    return { filtros, page, limit, total, items };
  });
  res.json(body);
}));

// ---------------------------------------------------------------------------
// GET /products/:productoId — detalle con atributos variables por tipo de producto
// ---------------------------------------------------------------------------
router.get('/products/:productoId', ah(async (req, res) => {
  const { productoId } = req.params;
  const product = await cacheAside(res, cache.keys.product(productoId), config.ttl.product, () =>
    db.productos.findOne({ productoId, activo: true }, { projection: PRODUCT_PROJECTION }));
  if (!product) throw notFound(`No existe el producto '${productoId}'.`);
  res.json(product);
}));

// ---------------------------------------------------------------------------
// POST /products — alta; la validación final la hace el $jsonSchema de MongoDB
// ---------------------------------------------------------------------------
router.post('/products', ah(async (req, res) => {
  assertObjectBody(req.body);
  rejectServerFields(req.body);
  const now = new Date();
  const doc = {
    activo: true,
    moneda: 'MXN',
    ...req.body,
    resumenResenas: { promedio: new Int32(0), total: new Int32(0) },
    creadoEn: now,
    actualizadoEn: now,
  };
  await db.productos.insertOne(doc);
  await cache.invalidateProduct(doc.productoId);
  delete doc._id;
  res.status(201).location(`products/${encodeURIComponent(doc.productoId)}`).json(doc);
}));

// ---------------------------------------------------------------------------
// PUT /products/:productoId — actualiza los campos enviados (validados por $jsonSchema)
// ---------------------------------------------------------------------------
router.put('/products/:productoId', ah(async (req, res) => {
  const { productoId } = req.params;
  assertObjectBody(req.body);
  rejectServerFields(req.body, ['productoId']);
  if (Object.keys(req.body).length === 0) throw badRequest('No se envió ningún campo para actualizar.');

  const updated = await db.productos.findOneAndUpdate(
    { productoId },
    { $set: { ...req.body, actualizadoEn: new Date() } },
    { returnDocument: 'after', projection: PRODUCT_PROJECTION },
  );
  if (!updated) throw notFound(`No existe el producto '${productoId}'.`);
  await cache.invalidateProduct(productoId);
  res.json(updated);
}));

// ---------------------------------------------------------------------------
// GET /products/:productoId/reviews — reseñas paginadas (más recientes primero)
// ---------------------------------------------------------------------------
router.get('/products/:productoId/reviews', ah(async (req, res) => {
  const { productoId } = req.params;
  const { page, limit, skip } = pagination(req.query, 10);

  const body = await cacheAside(res, cache.keys.reviews(productoId, page, limit), config.ttl.reviews, async () => {
    const product = await db.productos.findOne({ productoId }, { projection: { _id: 0, nombre: 1, resumenResenas: 1 } });
    if (!product) return null;
    const [total, docs] = await Promise.all([
      db.resenas.countDocuments({ productoId }),
      db.resenas.find({ productoId }).sort({ creadoEn: -1 }).skip(skip).limit(limit).toArray(),
    ]);
    const items = docs.map(({ _id, ...r }) => ({ resenaId: _id.toString(), ...r }));
    return { productoId, nombre: product.nombre, resumenResenas: product.resumenResenas, page, limit, total, items };
  });
  if (!body) throw notFound(`No existe el producto '${productoId}'.`);
  res.json(body);
}));

// ---------------------------------------------------------------------------
// POST /products/:productoId/reviews — registra reseña y recalcula resumenResenas
// ---------------------------------------------------------------------------
async function recalcularResumen(productoId) {
  const [agg] = await db.resenas.aggregate([
    { $match: { productoId } },
    { $group: { _id: null, promedio: { $avg: '$calificacion' }, total: { $sum: 1 } } },
  ]).toArray();
  const promedio = agg ? Math.round(agg.promedio * 10) / 10 : 0;
  const resumen = { promedio: new Double(promedio), total: new Int32(agg ? agg.total : 0) };
  await db.productos.updateOne({ productoId }, { $set: { resumenResenas: resumen, actualizadoEn: new Date() } });
  return { promedio, total: agg ? agg.total : 0 };
}

router.post('/products/:productoId/reviews', ah(async (req, res) => {
  const { productoId } = req.params;
  assertObjectBody(req.body);
  rejectServerFields(req.body);
  const exists = await db.productos.countDocuments({ productoId, activo: true }, { limit: 1 });
  if (!exists) throw notFound(`No existe el producto '${productoId}'.`);

  const doc = {
    compraVerificada: false,
    ...req.body,
    productoId,
    creadoEn: new Date(),
  };
  const { insertedId } = await db.resenas.insertOne(doc);
  const resumenResenas = await recalcularResumen(productoId);
  await Promise.all([cache.invalidateProduct(productoId), cache.invalidateReviews(productoId)]);

  delete doc._id;
  res.status(201).json({ resena: { resenaId: insertedId.toString(), ...doc }, resumenResenas });
}));

module.exports = { router, recalcularResumen };
