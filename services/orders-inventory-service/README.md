# orders-inventory-service (Entrega 2 — Rol 2)

Microservicio de Órdenes e Inventario (puerto interno `8003`).

- **Base de datos propia**: PostgreSQL 16 (`tienda_ordenes`).
- **Comunicación vía API HTTP**: consulta y vacía el carrito mediante `cart-service` (`:8002`) y valida productos contra `catalog-service` (`:8001`). Nunca consulta directamente MongoDB ni Redis.
- **Endpoints planificados**:
  - `GET /health`
  - `GET /inventory/:sku`
  - `POST /orders/confirm` (ejecuta `confirmar_compra()` dentro de transacción ACID con `FOR UPDATE`)
  - `GET /orders/customer/:clienteId` (historial de compras)
