# Estructura de Claves en Redis

Para respetar estrictamente la regla **"cada servicio es dueño de su base de datos"** y evitar que la política de desalojo (*eviction*) de una caché efímera afecte sesiones o carritos de clientes, Redis se divide en **dos instancias independientes**:

1. **`redis-catalog-cache`** (propiedad de `catalog-service`, política `allkeys-lru`, sin persistencia).
2. **`redis-cart`** (propiedad de `cart-service`, política `volatile-lru`, persistencia AOF).

---

## 1. Instancia `redis-cart` (Servicio de Carrito)

| Patrón de Clave | Tipo Redis | Ejemplo de Valor | TTL | Renovación / Invalidación |
|---|---|---|---|---|
| `cart:{userId}` | `HASH` | Campos `sku` -> JSON `{"productoId":"prod-ref-lg-001","nombre":"Refrigerador LG...","precio":18499.0,"cantidad":1}` | **7 días** (`604800 s`) | *Sliding expiration*: se renueva el TTL con `EXPIRE` en cada `HSET`; se elimina con `DEL` al confirmar compra (`POST /orders/confirm`). |
| `cart:meta:{userId}` | `HASH` | `updatedAt`, `itemCount`, `currency` | **7 días** (`604800 s`) | Se actualiza y elimina junto con `cart:{userId}`. |
| `session:{sessionId}` | `HASH` | `userId`, `email`, `nombre`, `role`, `createdAt`, `lastSeenAt` | **24 horas** (`86400 s`) | *Sliding expiration* en cada petición autenticada; se elimina con `DEL` en logout. |
| `user:sessions:{userId}` | `SET` | Conjunto de `sessionId` activos del usuario | **24 horas** (`86400 s`) | Permite cerrar todas las sesiones de un usuario. |

---

## 2. Instancia `redis-catalog-cache` (Servicio de Catálogo — Patrón Cache-Aside)

| Patrón de Clave | Tipo Redis | Ejemplo de Valor | TTL | Estrategia de Invalidación |
|---|---|---|---|---|
| `catalog:product:{productoId}` | `STRING` (JSON) | Documento completo del producto desde MongoDB | **5 min** (`300 s`) | **Invalidación explícita** (`DEL catalog:product:{productoId}`) cada vez que el producto se actualiza (`PUT/PATCH`), se desactiva (`DELETE`) o cambia su `resumenResenas`. |
| `catalog:version` | `STRING` (entero) | `"4"` | Sin TTL (persistente en memoria, inicia en `1`) | **Versionado de listados**: al crear/editar/eliminar cualquier producto se ejecuta `INCR catalog:version`. Invalida al instante todas las consultas filtradas sin usar `KEYS *`. |
| `catalog:list:v{ver}:{hashFiltros}` | `STRING` (JSON) | Respuesta paginada del catálogo (ej. `categoria=linea_blanca&min=10000&max=25000&page=1`) | **2 min** (`120 s`) | Invalidación instantánea por incremento de `{ver}` + expiración automática por TTL de 120 s. |
| `catalog:reviews:{productoId}:p{page}` | `STRING` (JSON) | Página de reseñas de un producto | **2 min** (`120 s`) | Se invalida al registrar una nueva reseña sobre `{productoId}`. |

---

## 3. Flujo Cache-Aside y Tolerancia a Fallos

1. **Lectura (`GET /api/catalog/products/{id}`)**:
   - Intentar `GET catalog:product:{id}` con timeout estricto (`<= 500 ms`).
   - **Cache HIT**: retornar JSON directo con cabecera `X-Cache: HIT`.
   - **Cache MISS**: consultar MongoDB (`productos.findOne({ productoId: id, activo: true })`), guardar en Redis con `SETEX catalog:product:{id} 300 <json>` y retornar con `X-Cache: MISS`.
   - **Fallo de Redis**: si Redis no responde o está apagado, registrar advertencia, **no colgar la petición**, consultar MongoDB directamente y retornar `200 OK` con cabecera `X-Cache: BYPASS` (degradación controlada).
2. **Escritura / Actualización (`PUT /api/catalog/products/{id}`)**:
   - Actualizar primero en MongoDB (fuente de verdad).
   - Ejecutar `DEL catalog:product:{id}` e `INCR catalog:version` en Redis para eliminar datos obsoletos.
