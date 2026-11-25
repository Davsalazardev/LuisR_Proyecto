# Documento de Decisiones de Diseño (Poliglot Persistence)

## 1. Matriz de Asignación de Datos por Base de Datos

| Entidad / Dato | Base de Datos | Servicio Propietario | Justificación Técnica |
|---|---|---|---|
| **Productos del catálogo** (nombre, categoría, precio base, imágenes, `atributos` variables por tipo) | **MongoDB** (Documental) | `catalog-service` | Una tienda departamental vende artículos heterogéneos: un refrigerador tiene capacidad en pies cúbicos, compresor y voltaje; una camisa tiene talla, corte y tela; una laptop tiene CPU, RAM y SSD. Modelar esto en SQL obligaría a tablas EAV lentas o decenas de columnas `NULL`. MongoDB permite un núcleo estricto validado con `$jsonSchema` y un subdocumento `atributos` polimórfico. |
| **Reseñas de productos** (`resenas`) | **MongoDB** (Documental) | `catalog-service` | Son contenido semiestructurado asociado al catálogo y leído frecuentemente junto al detalle del producto. Se almacenan en colección propia con `$jsonSchema` e índice `(productoId, creadoEn DESC)`. |
| **Caché de catálogo** (detalle y listados filtrados) | **Redis** (`redis-catalog-cache`) | `catalog-service` | El catálogo tiene una proporción muy alta de lecturas frente a escrituras (95% / 5%). El patrón *cache-aside* en memoria reduce drásticamente la latencia y descarga a MongoDB. |
| **Carrito de compras** (`cart:{userId}`) | **Redis** (`redis-cart`) | `cart-service` | Es estado transitorio de alta frecuencia de mutación (agregar/quitar cantidades), acceso por clave `userId` en O(1) y necesita expiración automática (TTL 7 días) para limpiar carritos abandonados sin *cron jobs*. |
| **Sesiones de usuario** (`session:{sessionId}`) | **Redis** (`redis-cart`) | `cart-service` | Requiere validación sub-milisegundo en cada petición y expiración automática (TTL 24 horas con *sliding expiration*). |
| **Clientes, Órdenes, Detalle de Orden e Inventario** | **PostgreSQL 16** (Relacional) | `orders-inventory-service` | La confirmación de compra exige garantías **ACID** estrictas: descontar existencias y crear la orden debe ocurrir de forma atómica. Además, la concurrencia sobre el último artículo en stock requiere bloqueos a nivel de fila (`SELECT ... FOR UPDATE`) y restricciones `CHECK (stock_disponible >= 0)` que impidan inventario negativo. |

---

## 2. Decisiones de Modelado Documental: ¿Embeber o Referenciar?

| Relación en MongoDB | Decisión | Motivo |
|---|---|---|
| **Producto → `atributos` específicos** (ej. dimensiones de refrigerador o tallas de camisa) | **Embeber** dentro del documento `productos` | Relación 1:1 de tamaño acotado; siempre se leen juntos en el detalle del producto en una sola operación de lectura. |
| **Producto → `resumenResenas` (`promedio`, `total`)** | **Embeber** (Patrón *Computed / Subset*) | Al listar el catálogo se muestran las estrellas promedio y cantidad de reseñas sin necesidad de `$lookup` ni consultas adicionales a `resenas`. |
| **Producto → `resenas` (lista completa)** | **Referenciar** en colección separada `resenas` vía `productoId` | Relación 1:N **no acotada**. Un producto popular podría acumular miles de reseñas, provocando crecimiento sin límite del documento (riesgo del límite de 16 MB en BSON), contención de escritura y documentos pesados en la caché de Redis. |

---

## 3. Estrategia de Caché (Cache-Aside), TTL e Invalidación

### ¿Por qué separar `redis-catalog-cache` de `redis-cart`?
1. **Aislamiento de servicios**: cumple al 100% la regla *"cada servicio es dueño de su base de datos"*.
2. **Políticas de memoria incompatibles**:
   - La caché de catálogo usa **`allkeys-lru`** sin persistencia en disco (si se llena la RAM, descarta el producto menos consultado y se vuelve a leer de MongoDB sin problema).
   - El carrito y sesiones usan **`volatile-lru`** con persistencia **AOF** (`appendfsync everysec`) para no perder compras en curso por un reinicio ni ser desalojados por el tráfico del catálogo.

### Qué se cachea, con qué TTL y cómo se invalida

| Dato cacheado | Clave Redis | TTL | Invalidación |
|---|---|---|---|
| Detalle de producto | `catalog:product:{productoId}` | **300 s (5 min)** | `DEL catalog:product:{productoId}` al ejecutar `PUT/PATCH/DELETE` del producto o al registrar una nueva reseña (que recalcula `resumenResenas`). |
| Listados filtrados (categoría/precio) | `catalog:list:v{ver}:{hashFiltros}` | **120 s (2 min)** | `INCR catalog:version` cuando cambia cualquier producto. Invalida todos los listados en O(1) sin usar `KEYS *`. |
| Reseñas paginadas | `catalog:reviews:{productoId}:p{page}` | **120 s (2 min)** | Invalidación explícita al insertar una reseña en `{productoId}`. |
| Carrito de compra | `cart:{userId}` | **604800 s (7 días)** | `EXPIRE` en cada modificación; `DEL` al confirmar la orden vía API. |
| Sesión de usuario | `session:{sessionId}` | **86400 s (24 horas)** | `EXPIRE` en actividad; `DEL` al cerrar sesión. |

---

## 4. Comunicación entre Servicios y Tolerancia a Fallos

- **Cero acceso cruzado a bases de datos**: `orders-inventory-service` **nunca** se conecta a Redis ni a MongoDB. Al confirmar una compra:
  1. Llama vía HTTP a `GET http://10.0.2.20:8002/carts/{userId}` para obtener los artículos del carrito.
  2. (Opcional) Valida estado activo en `catalog-service` vía HTTP.
  3. Ejecuta la transacción ACID `confirmar_compra(...)` en su propio PostgreSQL.
  4. Si hace `COMMIT`, llama vía HTTP a `DELETE http://10.0.2.20:8002/carts/{userId}` para vaciar el carrito.
- **Timeouts y respuestas controladas**:
  - Todas las llamadas HTTP internas usan un timeout máximo de **3 segundos** (y Redis caché **500 ms**).
  - Si **Redis Caché** cae -> `catalog-service` hace *fallback* a MongoDB y responde `200 OK` con cabecera `X-Cache: BYPASS` (y `GET /health` reporta `status: "degraded"`).
  - Si **Redis Carrito** o **Catálogo** caen -> el gateway/servicio devuelve `503 Service Unavailable` con JSON estructurado en menos de 3 segundos, sin colgar la petición.
