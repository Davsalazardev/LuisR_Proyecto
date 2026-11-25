# Organización del Equipo, Reparto Detallado y Flujo Git

**Profesor:** Luis Roberto Flores  
**Repositorio:** https://github.com/Davsalazardev/LuisR_Proyecto

> Cada integrante es responsable de su módulo y debe registrar **commits propios** en su rama del repositorio Git (sin subir `.env`, llaves `.pem` ni credenciales).

---

## 1. Resumen del Equipo (6 Integrantes)

| Integrante | Rol / Módulo | Rama Git | Estado |
|---|---|---|---|
| **David Eduardo Salazar Mireles** | Arquitectura, diagramas, decisiones de diseño, esquemas y scripts base (PostgreSQL/MongoDB/Redis), Docker Compose, scripts AWS, repo Git y Entrega 1 | `main` | **Completado** |
| **German David Hernandez Castro** | Infraestructura AWS (VPC, Security Groups, EC2, BDs) y despliegue detrás de Nginx | `feat/infra-aws` | Pendiente (Avance 1 AWS + 2 + Final) |
| **Lizbeth Segundo Garcia** | Servicio de Órdenes e Inventario (`services/orders-inventory-service/`, PostgreSQL) | `feat/orders-service` | Pendiente (Avance 2 + Final) |
| **Bran Elton Duque Hernandez** | Servicio de Catálogo (`services/catalog-service/`, MongoDB + `$jsonSchema` + reseñas) | `feat/catalog-mongodb` | Pendiente (Avance 2 + Final) |
| **Abraham** | Servicio de Carrito (`services/cart-service/`, Redis) + caché *cache-aside* + prueba de rendimiento | `feat/cart-redis-cache` | Pendiente (Avance 2 + Final) |
| **Roque Martinez** | Contrato API (Postman/Swagger), integración, pruebas de fallos/concurrencia y reporte final | `feat/integration-tests` | Pendiente (Avance 2 + Final) |

---

## 2. Qué le Toca Hacer a Cada Integrante (Paso a Paso)

### 2.1 German David Hernandez Castro — Infraestructura AWS, Seguridad y Despliegue
- **Rama Git:** `feat/infra-aws`
- **Para el viernes 27 de noviembre (Avance 2 + pendiente de AWS):**
  - [ ] Levantar en AWS la VPC (`10.0.0.0/16`), subred pública (`10.0.1.0/24`), subred privada (`10.0.2.0/24`), los 4 Security Groups y las 4 instancias EC2 `t3.micro` usando `infrastructure/aws/cloudshell-all-in-one.sh` (o `provision-aws.sh`) desde AWS CloudShell.
  - [ ] Confirmar que **MongoDB, Redis Caché, Redis Carrito y PostgreSQL** estén levantados en sus EC2 y que los puertos **`5432`, `27017` y `6379` NO estén abiertos a `0.0.0.0/0`**.
  - [ ] Guardar capturas de evidencia: instancias EC2 en *Running*, reglas Inbound de los 4 Security Groups y pruebas de conexión vía Bastión SSH a las 3 bases de datos.
  - [ ] Compartir IPs privadas y preparar `infrastructure/ec2/gateway/nginx.conf` para recibir los 3 servicios.
- **Para el miércoles 2 de diciembre (Entrega Final):**
  - [ ] Desplegar los contenedores de `catalog-service` (:8001), `cart-service` (:8002) y `orders-inventory-service` (:8003) en sus EC2 detrás de Nginx (`:80`).
  - [ ] Comprobar desde fuera de AWS que `curl http://<IP_GATEWAY>/health` responde `200` y que los puertos `5432`, `27017` y `6379` están bloqueados desde Internet.
  - [ ] Control de costos: detener (`Stop`) las EC2 al terminar pruebas y al cerrar el proyecto.

---

### 2.2 Lizbeth Segundo Garcia — Servicio de Órdenes e Inventario (PostgreSQL)
- **Carpeta / Rama Git:** `services/orders-inventory-service/` · `feat/orders-service`
- **Base ya lista en el repo:** `databases/postgres/init.sql` (4 tablas, `CHECK (stock_disponible >= 0)` y función `confirmar_compra` con `SELECT ... FOR UPDATE`) y `infrastructure/ec2/orders/docker-compose.yml`.
- **Para el viernes 27 de noviembre (Avance 2 — servicio funcionando por separado):**
  - [ ] Levantar PostgreSQL local con Docker Compose y verificar que cargue `init.sql`.
  - [ ] Programar la API REST en `services/orders-inventory-service/` (puerto `8003`) conectada **únicamente** a PostgreSQL (`tienda_ordenes`).
  - [ ] Implementar los endpoints:
    - `GET /health` (valida conexión a PostgreSQL y responde estado JSON).
    - `GET /inventory/:sku` (consulta existencias disponibles).
    - `POST /orders/confirm`: ejecuta la transacción ACID `confirmar_compra()` (crea orden y descuenta stock; si no hay existencias hace `ROLLBACK` y regresa `409 Conflict` sin dejar datos a medias). *Para probar sola en Avance 2 puede aceptar ítems en el body.*
    - `GET /orders/customer/:clienteId`: consulta el historial de compras del cliente con sus ítems.
  - [ ] Agregar `Dockerfile` y capturas de evidencia (compra exitosa, rechazo por falta de stock sin stock negativo e historial).
- **Para el miércoles 2 de diciembre (Entrega Final — integración):**
  - [ ] Conectar `POST /orders/confirm` por **API HTTP** a `cart-service:8002` (leer carrito antes de comprar y llamar `DELETE /carts/:userId` tras confirmar; **nunca** consultar Redis directo) con timeout de **3 segundos** y error controlado (`503`) si falla.

---

### 2.3 Bran Elton Duque Hernandez — Servicio de Catálogo (MongoDB + Reseñas)
- **Carpeta / Rama Git:** `services/catalog-service/` · `feat/catalog-mongodb`
- **Base ya lista en el repo:** `databases/mongodb/init.js` (`$jsonSchema` en `productos` y `resenas`, índices y datos semilla), `databases/mongodb/verify.js` e `infrastructure/ec2/catalog/docker-compose.yml`.
- **Para el viernes 27 de noviembre (Avance 2 — servicio funcionando por separado):**
  - [ ] Levantar MongoDB local con Docker Compose y verificar `$jsonSchema` e índices corriendo `databases/mongodb/verify.js`.
  - [ ] Programar la API REST en `services/catalog-service/` (puerto `8001`) conectada a MongoDB (`tienda_catalogo`).
  - [ ] Implementar los endpoints:
    - `GET /health` (reporta estado de MongoDB y de Redis Caché).
    - `GET /products`: listar catálogo y **filtrar por categoría (`categoria`) y rango de precio (`precioMin`, `precioMax`)**.
    - `GET /products/:productoId`: detalle de un producto con sus atributos variables (refrigerador, camisa, laptop, etc.).
    - `POST /products` y `PUT /products/:productoId`: alta y actualización de producto (respetando `$jsonSchema` y dejando el punto de invalidación de caché para integrar con Abraham).
    - `POST /products/:productoId/reviews` y `GET /products/:productoId/reviews`: registrar y consultar reseñas (actualizando `resumenResenas`).
  - [ ] Agregar `Dockerfile` y capturas de evidencia (listado, filtros, detalle, reseñas y rechazo de documento inválido por `$jsonSchema`).
- **Para el miércoles 2 de diciembre (Entrega Final):**
  - [ ] Coordinar con Abraham la integración final de *cache-aside* e invalidación en `catalog-service` y desplegar en `ec2-catalog` con German.

---

### 2.4 Abraham — Servicio de Carrito + Caché Cache-Aside (Redis) + Rendimiento
- **Carpeta / Rama Git:** `services/cart-service/` (y caché en `services/catalog-service/`) · `feat/cart-redis-cache`
- **Base ya lista en el repo:** `databases/redis/estructura-claves.md`, `redis-cart.conf`, `redis-cache.conf`, `verify.sh` e `infrastructure/ec2/cart/docker-compose.yml`.
- **Para el viernes 27 de noviembre (Avance 2 — servicio funcionando por separado):**
  - [ ] Levantar Redis local con Docker Compose y programar `services/cart-service/` (puerto `8002`) conectado a `redis-cart`:
    - `GET /health` (verifica `PING` a Redis y devuelve error controlado si cae).
    - Sesiones con expiración (`session:{sessionId}`, TTL 24 h): crear, validar y cerrar sesión.
    - Carrito con expiración (`cart:{userId}`, TTL 7 días): consultar (`GET /carts/:userId`), agregar (`POST /carts/:userId/items`), modificar cantidad (`PATCH /carts/:userId/items/:sku`), eliminar (`DELETE /carts/:userId/items/:sku`) y vaciar (`DELETE /carts/:userId`).
  - [ ] En coordinación con Elton, integrar el patrón **cache-aside** en `catalog-service` usando `redis-catalog-cache`:
    - Cachear detalle (`TTL 300 s`) y listados (`TTL 120 s`) devolviendo cabecera `X-Cache: HIT / MISS / BYPASS`.
    - Invalidar caché (`DEL` + `INCR catalog:version`) al actualizar un producto o crear una reseña.
    - *Fallback* automático a MongoDB si Redis Caché cae (timeout `500 ms`, nunca colgarse).
  - [ ] Agregar `Dockerfile` y capturas de evidencia (carrito/sesiones con TTL + `HIT`/`MISS` e invalidación en catálogo).
- **Para el miércoles 2 de diciembre (Entrega Final — prueba de rendimiento):**
  - [ ] Ejecutar la **prueba de rendimiento**: 100 peticiones al mismo endpoint del catálogo **con y sin caché** (k6, JMeter, Locust o script), entregar tabla, gráfica comparativa y conclusiones.

---

### 2.5 Roque Martinez — Integración, Swagger/Postman, Pruebas y Entrega Final
- **Rama Git:** `feat/integration-tests`
- **Para el viernes 27 de noviembre (Avance 2):**
  - [ ] Acordar y publicar las rutas y formatos JSON estándar con Lizbeth, Elton y Abraham para que los 3 servicios coincidan.
  - [ ] Crear la **colección de Postman o documentación Swagger/OpenAPI** (o interfaz mínima) probando los 3 servicios por separado y subirla al repositorio.
  - [ ] Compilar las evidencias individuales del equipo para la Entrega 2.
- **Para el miércoles 2 de diciembre (Entrega Final):**
  - [ ] Probar el flujo integrado completo pasando por Nginx en AWS (`ec2-gateway-bastion`): catálogo → filtros → reseñas → carrito → confirmar compra → inventario descontado y carrito vacío → historial de compras.
  - [ ] Ejecutar la **prueba de fallos**: apagar un contenedor real (ej. Redis Caché y luego Redis Carrito o Catálogo), documentar la respuesta controlada (sin colgarse) y la recuperación al volver a encenderlo.
  - [ ] Ejecutar la **prueba de concurrencia**: dos compras simultáneas del último artículo en stock (`REF-LG-001`, stock = 1), documentando que una pasa (`201`), la otra se rechaza (`409`) y por qué el inventario nunca queda en negativo.
  - [ ] Armar el **reporte final** (resultados de las 3 pruebas y conclusiones), coordinar el **video** y el guion de la **presentación (máx. 10 min)**.

---

## 3. Dependencias y Orden de Trabajo para el Viernes 27 (Avance 2)

> **Importante:** Nadie tiene que esperar a German para programar ni probar su servicio; cada quien puede levantar su BD local con los `docker-compose.yml` del repo hoy mismo.

| Integrante | ¿Necesita esperar a alguien para el Avance 2? | ¿Quién depende de su avance? |
|---|---|---|
| **German** | **No** (los scripts AWS ya están listos). Debe levantar AWS primero. | Todos, para subir los contenedores a EC2. |
| **Elton** | **No** (corre MongoDB local con Docker). | **Abraham** (para agregar *cache-aside* al catálogo) y **Roque** (para Postman). |
| **Abraham** | `cart-service`: **No**. Caché del catálogo: necesita `GET/PUT /products` de **Elton**. | **Roque** (para Postman) y **Lizbeth** (al integrar en Entrega Final). |
| **Lizbeth** | **No** (corre PostgreSQL local con `init.sql`). | **Roque** (para Postman) y **German** (su `Dockerfile`). |
| **Roque** | Necesita las rutas/respuestas de **Elton, Abraham y Lizbeth** (jueves noche) para probar Postman. | Todo el equipo depende de que defina el contrato de rutas desde el inicio. |

---

## 4. Reglas Git y Cronograma

- **Ramas:** trabajar siempre en su rama (`feat/...`) y hacer Pull Request a `main`.
- **Seguridad:** verificar `git status` antes de cada commit; **nunca** subir `.env`, `*.pem` ni credenciales.

| Fecha | Entrega | Qué se entrega |
|---|---|---|
| **20 nov** | Entrega 1 | Diseño de arquitectura, decisiones, modelos de datos, reparto, repo Git y EC2 con BDs. |
| **Viernes 27 nov** | **Entrega 2** | Los 3 servicios funcionando por separado (con `GET /health`), evidencia de cada uno, colección Postman/Swagger, AWS regularizado y commits por integrante. |
| **Miércoles 2 dic** | **Entrega Final** | Integración completa en EC2 detrás de Nginx, pruebas de rendimiento, fallos y concurrencia con conclusiones, reporte y video. |
| **3 y 4 dic** | Presentación | Demostración en vivo (máx. 10 min) con participación de todo el equipo. |
