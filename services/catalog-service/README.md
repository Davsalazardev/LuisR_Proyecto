# catalog-service (Entrega 2 — Bran Elton Duque Hernandez / Abraham)

Microservicio de Catálogo (puerto interno `8001`).

- **Base de datos propia**: MongoDB 7 (`tienda_catalogo`, colecciones `productos` y `resenas`).
- **Caché propia**: Redis 7 (`redis-catalog-cache`, patrón *cache-aside* con TTL e invalidación).
- **Endpoints planificados**:
  - `GET /health`
  - `GET /products` (filtros: `categoria`, `precioMin`, `precioMax`, `q`, paginación)
  - `GET /products/:productoId`
  - `POST /products` / `PUT /products/:productoId` (invalida caché en Redis)
  - `GET /products/:productoId/reviews`
  - `POST /products/:productoId/reviews`
