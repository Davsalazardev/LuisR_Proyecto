# catalog-service (Entrega 2 — Bran Elton Duque Hernandez)

Microservicio de Catálogo — Node.js 20 + Express, puerto interno **`8001`**.

- **Base de datos propia**: MongoDB 7 (`tienda_catalogo`, colecciones `productos` y `resenas`, validadas con `$jsonSchema` desde `databases/mongodb/init.js`).
- **Caché propia**: Redis 7 (`tienda-redis-cache`, *cache-aside* con TTL e invalidación, ver `databases/redis/estructura-claves.md`). Si Redis falla, el servicio sigue respondiendo desde MongoDB (`X-Cache: BYPASS`, `/health` = `degraded`).
- **Publicado por Nginx** en `http://<IP_GATEWAY>/api/catalog/…` → `10.0.1.20:8001/…`

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/health` | Estado de MongoDB (y Redis). `200` si MongoDB responde, `503` si no. |
| `GET` | `/products` | Catálogo activo. Filtros: `categoria`, `precioMin`, `precioMax`, `q` (texto), `page`, `limit` (≤ 50). Orden por precio. |
| `GET` | `/products/:productoId` | Detalle con `atributos` variables según el tipo de producto. |
| `POST` | `/products` | Alta. El servidor pone `creadoEn`, `actualizadoEn`, `resumenResenas` (0/0), y por defecto `activo: true`, `moneda: "MXN"`. |
| `PUT` | `/products/:productoId` | Actualiza los campos enviados (`productoId` es inmutable). |
| `GET` | `/products/:productoId/reviews` | Reseñas paginadas (`page`, `limit`), más recientes primero, con `resumenResenas`. |
| `POST` | `/products/:productoId/reviews` | Registra una reseña y recalcula `resumenResenas` (promedio y total) del producto. Una reseña por cliente y producto. |

### Validación y errores

La validación de negocio la hace el **`$jsonSchema` de MongoDB** (fuente de verdad). Si MongoDB rechaza un documento (code `121`), el servicio responde:

```json
HTTP 400
{
  "error": "SCHEMA_VALIDATION_FAILED",
  "message": "MongoDB rechazó el documento: no cumple el $jsonSchema de la colección (code 121).",
  "details": [ { "regla": "minimum", "campo": "precio", "valor": -10, ... } ]
}
```

| Código | Cuándo |
|---|---|
| `400` | JSON mal formado, parámetros inválidos, campos administrados por el servidor, o rechazo de `$jsonSchema` |
| `404` | Producto inexistente o inactivo |
| `409` | `productoId`/`sku` duplicado, o el cliente ya reseñó ese producto |
| `503` | MongoDB no responde (timeout 3 s) |

### Caché (cabecera `X-Cache`)

| Dato | Clave | TTL | Invalidación |
|---|---|---|---|
| Detalle | `catalog:product:{productoId}` | 300 s | `DEL` en `PUT` y al registrar reseña |
| Listados | `catalog:list:v{ver}:{hash}` | 120 s | `INCR catalog:version` en cualquier alta/edición/reseña |
| Reseñas | `catalog:reviews:{productoId}:p{page}:l{limit}` | 120 s | `DEL` al registrar reseña |

## Variables de entorno

Ver [`.env.example`](.env.example). En `ec2-catalog` MongoDB y Redis escuchan solo en `127.0.0.1`, por eso el contenedor usa `--network host`.

## Despliegue en `ec2-catalog` (desde AWS CloudShell)

```bash
# En la raíz del repo: empaquetar el servicio + init.js de MongoDB
tar -czf catalog-service.tar.gz services/catalog-service databases/mongodb/init.js
# Subirlo a CloudShell (Acciones → Cargar archivo) y ejecutar:
bash deploy-from-cloudshell.sh ~/catalog-service.tar.gz
```

El script copia el paquete vía Bastión, escribe el `.env` solo en la EC2, alinea MongoDB con `databases/mongodb/init.js` (`deploy/align-db-*.js`), construye la imagen y levanta el contenedor:

```bash
docker build -t catalog-service:1.0 .
docker run -d --name catalog-service --restart unless-stopped --network host --env-file .env catalog-service:1.0
```

Pruebas vía Gateway (listado, filtros, detalle, alta/edición, rechazos de `$jsonSchema` y reseñas):

```bash
bash deploy/pruebas-gateway.sh <IP_GATEWAY>
```
