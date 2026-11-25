# cart-service (Entrega 2 — Abraham)

Microservicio de Carrito y Sesiones (puerto interno `8002`).

- **Base de datos propia**: Redis 7 (`redis-cart`, persistencia AOF).
- **Endpoints planificados**:
  - `GET /health`
  - `POST /sessions` / `GET /sessions/:sessionId` / `DELETE /sessions/:sessionId`
  - `GET /carts/:userId`
  - `POST /carts/:userId/items`
  - `PATCH /carts/:userId/items/:sku`
  - `DELETE /carts/:userId/items/:sku`
  - `DELETE /carts/:userId` (invocado vía API por `orders-inventory-service` tras confirmar compra)
