# Plan de Trabajo en Cadena (Relevos) — Tienda Departamental en AWS

**Profesor:** Luis Roberto Flores  
**Repositorio:** https://github.com/Davsalazardev/LuisR_Proyecto

> **Regla de trabajo (carrera de relevos):** cada integrante trabaja **un solo turno**, deja su parte **100% terminada y subida a `main`**, le pasa la estafeta al siguiente y **ya no vuelve a programar nada** (solo repasar para la presentación del 3–4 de diciembre).  
> Cada integrante debe tener **commits propios** en el repositorio y **nunca** subir `.env`, llaves `.pem` ni credenciales.

---

## Orden de Relevos y Fechas Límite

```text
[Turno 0] David   (LISTO)                      -> Base del proyecto, BDs, scripts AWS y Entrega 1
    │
    ▼
[Turno 1] German  (Mié 25 nov - Jue 26 10:00)  -> Levanta AWS completo (EC2 + BDs + Nginx) y TERMINA
    │
    ▼
[Turno 2] Elton   (Jue 26 10:00 - Jue 26 20:00)-> Hace y sube catalog-service (MongoDB) y TERMINA
    │
    ▼
[Turno 3] Abraham (Jue 26 20:00 - Vie 27 13:00)-> Hace cart-service + caché en catálogo + prueba rendimiento y TERMINA
    │
    ▼
[Turno 4] Lizbeth (Vie 27 13:00 - Vie 27 21:00)-> Hace orders-inventory-service ya conectado a cart-service y TERMINA
    │                                             ══► ENTREGA 2 (Viernes 27 nov): AWS + 3 servicios listos
    ▼
[Turno 5] Roque   (Sáb 28 nov - Mar 1 dic)     -> Postman/Swagger, pruebas de fallos y concurrencia, reporte y video
                                                  ══► ENTREGA FINAL (Miércoles 2 dic)
```

---

## Detalle Exacto de Cada Turno

### Turno 0 — David Eduardo Salazar Mireles *(COMPLETADO)*
- **Ya entregado:** Arquitectura, diagramas, decisiones de diseño, esquemas y scripts de PostgreSQL (`init.sql`), MongoDB (`init.js` con `$jsonSchema` e índices) y Redis (`estructura-claves.md`, `.conf`), Docker Compose, scripts AWS (`cloudshell-all-in-one.sh`), `.gitignore`, `.env.example`, repositorio GitHub y documento de Entrega 1.
- **Estado:** Terminado. No tiene pendientes de código.

---

### Turno 1 — German David Hernandez Castro *(Miércoles 25 nov → Jueves 26 nov, 10:00 a.m.)*
- **Rama Git:** `feat/infra-aws` → merge a `main`
- **Qué recibe:** El script listo `infrastructure/aws/cloudshell-all-in-one.sh` y `infrastructure/ec2/gateway/nginx.conf`.
- **Qué debe hacer (en una sola sentada):**
  - [ ] Ejecutar `infrastructure/aws/cloudshell-all-in-one.sh` en AWS CloudShell para crear la VPC (`10.0.0.0/16`), subredes, los 4 Security Groups (con `5432`, `27017` y `6379` cerrados a Internet) y las 4 EC2 `t3.micro` con MongoDB, Redis Caché, Redis Carrito y PostgreSQL levantados.
  - [ ] Dejar configurado Nginx en `ec2-gateway-bastion` (`:80`) enrutando `/api/catalog/` → `10.0.1.20:8001`, `/api/cart/` → `10.0.1.30:8002` y `/api/orders/` → `10.0.1.40:8003` (así cuando sus compañeros levanten su contenedor, Nginx ya funcionará solo).
  - [ ] Subir al repo sus capturas de AWS (4 EC2 *Running*, Security Groups sin BDs públicas y conexión vía Bastión a las 3 BDs) y pasar por mensaje privado al grupo las IPs + credenciales + llave `.pem` (**nunca** subir `.pem` ni `.env` a GitHub).
- **Cuando avisa en el grupo:** *"Listo AWS, pasa Elton"* → **German termina 100% su parte.** *(Solo apagar las EC2 al terminar la presentación para no generar costos).*

---

### Turno 2 — Bran Elton Duque Hernandez *(Jueves 26 nov, 10:00 a.m. → 8:00 p.m.)*
- **Carpeta / Rama Git:** `services/catalog-service/` · `feat/catalog-mongodb` → merge a `main`
- **Qué recibe:** `ec2-catalog` (`10.0.1.20`) ya corriendo con MongoDB 7 (`$jsonSchema`, índices y datos semilla de `databases/mongodb/init.js`).
- **Qué debe hacer (en una sola sentada):**
  - [ ] Programar completo `services/catalog-service/` (puerto `8001`, con `Dockerfile`) conectado a MongoDB:
    - `GET /health` (estado de MongoDB).
    - `GET /products` (listar catálogo + filtros `categoria`, `precioMin`, `precioMax`).
    - `GET /products/:productoId` (detalle con atributos variables según tipo de producto).
    - `POST /products` y `PUT /products/:productoId` (respetando `$jsonSchema`).
    - `POST /products/:productoId/reviews` y `GET /products/:productoId/reviews` (registrar y consultar reseñas actualizando `resumenResenas`).
  - [ ] Desplegar el contenedor en `ec2-catalog` (`:8001`), comprobar que responde vía `http://<IP_GATEWAY>/api/catalog/products` y guardar capturas de prueba (listado, filtros, reseñas y rechazo de `$jsonSchema`).
  - [ ] Hacer commit y merge a `main`.
- **Cuando avisa en el grupo:** *"Listo catalog-service en `main`, pasa Abraham"* → **Elton termina 100% su parte.**

---

### Turno 3 — Abraham *(Jueves 26 nov 8:00 p.m. → Viernes 27 nov, 1:00 p.m.)*
- **Carpeta / Rama Git:** `services/cart-service/` y capa de caché en `services/catalog-service/` · `feat/cart-redis-cache` → merge a `main`
- **Qué recibe:** `ec2-cart` (`10.0.1.30`) con Redis Carrito, `ec2-catalog` (`10.0.1.20`) con Redis Caché y el `catalog-service` ya terminado por Elton en `main`.
- **Qué debe hacer (en una sola sentada):**
  - [ ] Programar completo `services/cart-service/` (puerto `8002`, con `Dockerfile`) conectado a `redis-cart`:
    - `GET /health` (verifica `PING` a Redis y devuelve error controlado si cae).
    - Sesiones con expiración (`session:{sessionId}`, TTL 24 h): crear, validar y cerrar sesión.
    - Carrito con expiración (`cart:{userId}`, TTL 7 días): `GET /carts/:userId`, `POST /carts/:userId/items`, `PATCH /carts/:userId/items/:sku`, `DELETE /carts/:userId/items/:sku` y `DELETE /carts/:userId` (vaciar carrito).
  - [ ] Desplegar `cart-service` en `ec2-cart` (`:8002`) y verificar vía `http://<IP_GATEWAY>/api/cart/...`.
  - [ ] Agregar a `services/catalog-service/` el patrón **cache-aside** con `redis-catalog-cache`:
    - Cachear detalle (`TTL 300 s`) y listados (`TTL 120 s`) devolviendo cabecera `X-Cache: HIT / MISS / BYPASS`.
    - Invalidar caché (`DEL` + `INCR catalog:version`) en `PUT /products/:productoId` y nuevas reseñas.
    - Timeout de `500 ms` y *fallback* automático a MongoDB si Redis Caché está apagado.
    - Redesplegar `catalog-service` en `ec2-catalog`.
  - [ ] **Hacer de una vez la Prueba de Rendimiento:** correr 100 peticiones al mismo endpoint del catálogo con y sin caché (k6, JMeter, Locust o script), guardar la tabla, gráfica y conclusiones en `docs/pruebas-rendimiento.md` (o carpeta de evidencias) junto con sus capturas de Entrega 2.
  - [ ] Hacer commit y merge a `main`.
- **Cuando avisa en el grupo:** *"Listo cart-service, caché y prueba de rendimiento en `main`, pasa Lizbeth"* → **Abraham termina 100% su parte.**

---

### Turno 4 — Lizbeth Segundo Garcia *(Viernes 27 nov, 1:00 p.m. → 9:00 p.m.)*
- **Carpeta / Rama Git:** `services/orders-inventory-service/` · `feat/orders-service` → merge a `main`
- **Qué recibe:** `ec2-orders` (`10.0.1.40`) con PostgreSQL 16 (`init.sql` ya cargado) y `cart-service` (`10.0.1.30:8002`) **ya corriendo y terminado por Abraham**.
- **Qué debe hacer (en una sola sentada):**
  - [ ] Programar completo `services/orders-inventory-service/` (puerto `8003`, con `Dockerfile`) conectado únicamente a PostgreSQL (`tienda_ordenes`):
    - `GET /health` (verifica conexión a PostgreSQL).
    - `GET /inventory/:sku` (consulta existencias).
    - `POST /orders/confirm`: consulta el carrito llamando por **API HTTP** a `http://10.0.1.30:8002/carts/:userId` (timeout 3 s, nunca directo a Redis), ejecuta la transacción ACID `confirmar_compra()` con `SELECT ... FOR UPDATE` (si falta stock hace `ROLLBACK` y devuelve `409 Conflict` sin datos a medias), y al confirmar llama por HTTP a `DELETE http://10.0.1.30:8002/carts/:userId` para vaciar el carrito.
    - `GET /orders/customer/:clienteId` (historial de compras del cliente con sus ítems).
  - [ ] Desplegar `orders-inventory-service` en `ec2-orders` (`:8003`), verificar vía `http://<IP_GATEWAY>/api/orders/...` y guardar sus capturas de prueba (compra exitosa, carrito vacío, stock descontado, rechazo sin stock e historial).
  - [ ] Hacer commit y merge a `main`.
- **Cuando avisa en el grupo:** *"Listo orders-inventory-service en `main`, pasa Roque"* → **Lizbeth termina 100% su parte y queda lista la ENTREGA 2 (viernes 27 nov) con los 3 servicios funcionando.**

---

### Turno 5 — Roque Martinez *(Sábado 28 nov → Martes 1 dic, para Entrega Final del Miércoles 2 dic)*
- **Rama Git:** `feat/integration-tests` → merge a `main`
- **Qué recibe:** **TODO el sistema ya programado y desplegado en AWS** (EC2 + Nginx + 3 servicios + 3 BDs) y la prueba de rendimiento ya hecha por Abraham.
- **Qué debe hacer (sin depender de nadie más):**
  - [ ] Crear y subir la colección de **Postman o Swagger/OpenAPI** (o interfaz mínima) probando todas las rutas públicas detrás de `http://<IP_GATEWAY>/api/...`.
  - [ ] Ejecutar y documentar la **Prueba de Fallos:** apagar un contenedor en EC2 (ej. `tienda-redis-cache` y luego `tienda-redis-cart`), capturar que el sistema responde con error controlado / degradación (sin quedarse colgado) y demostrar cómo se recupera al encenderlo.
  - [ ] Ejecutar y documentar la **Prueba de Concurrencia:** disparar 2 compras simultáneas sobre el último artículo en existencia (`REF-LG-001`, stock = 1), demostrar que una pasa (`201`), la otra falla (`409`) y explicar por qué el inventario queda en `0` y nunca en negativo.
  - [ ] Armar el **documento final de pruebas y conclusiones** (integrando la prueba de rendimiento de Abraham + fallos + concurrencia), grabar el **video** y armar la **presentación (máx. 10 min)** para el 3–4 de diciembre.
  - [ ] Hacer commit y merge a `main`.
- **Al terminar el martes 1 dic:** **Proyecto 100% listo para la Entrega Final del miércoles 2 de diciembre.**

---

## Nota sobre la Presentación (3 y 4 de diciembre)
Aunque cada integrante terminó su parte en su turno, para la demostración en vivo (máx. 10 minutos) todos deben participar y poder responder preguntas básicas sobre el sistema completo.
