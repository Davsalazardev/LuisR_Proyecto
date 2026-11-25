# Organización del Equipo, Reparto de Tareas y Flujo Git

**Profesor:** Luis Roberto Flores  
**Repositorio:** https://github.com/Davsalazardev/LuisR_Proyecto

> Cada integrante es responsable de su módulo y debe registrar **commits propios** en el repositorio Git.

---

## 1. Estado Actual y Reparto de Módulos (6 Integrantes)

| Integrante | Estado / Rol | Módulo y Rama Git | Tareas Asignadas |
|---|---|---|---|
| **David Eduardo Salazar Mireles** | **Completado (Entrega 1 base)** | `main` | Diseño de arquitectura, diagramas, documento de decisiones, esquemas y scripts base de PostgreSQL/MongoDB/Redis, Docker Compose, scripts AWS, `.gitignore`/`.env.example`, repositorio GitHub y Entrega 1. |
| **German David Hernandez Castro** | **Infraestructura AWS y Despliegue** | `feat/infra-aws` | **Pendiente de AWS (urgente):** crear VPC, subredes, Security Groups (puertos `5432`, `27017` y `6379` cerrados a Internet) y las 4 EC2 `t3.micro` usando `infrastructure/aws/cloudshell-all-in-one.sh`; levantar las 3 BDs y sacar evidencias. **Entrega 2 y Final:** configurar Nginx con las IPs privadas, desplegar los 3 servicios en EC2 y controlar costos (detener instancias al terminar pruebas). |
| **Lizbeth Segundo Garcia** | **Servicio de Órdenes e Inventario** | `services/orders-inventory-service/` · `feat/orders-service` | Implementar API REST (:8003) conectada solo a PostgreSQL (`databases/postgres/init.sql`): `GET /health`, `GET /inventory/:sku`, `POST /orders/confirm` (consulta carrito vía HTTP a `cart-service`, ejecuta transacción ACID `confirmar_compra` con `SELECT ... FOR UPDATE`, devuelve `409` sin datos a medias si falta stock y vacía carrito vía HTTP), `GET /orders/customer/:clienteId` (historial), timeouts de 3 s y `Dockerfile`. |
| **Bran Elton Duque Hernandez** | **Servicio de Catálogo (MongoDB)** | `services/catalog-service/` · `feat/catalog-mongodb` | Implementar API REST (:8001) conectada a MongoDB (`databases/mongodb/init.js`): verificar `$jsonSchema` e índices, `GET /health`, `GET /products` (listar y filtrar por categoría y precio), `GET /products/:productoId` (detalle con atributos variables), `POST/PUT /products` (con hook para invalidar caché), `POST/GET /products/:productoId/reviews` y `Dockerfile`. |
| **Abraham** | **Carrito + Caché Redis + Rendimiento** | `services/cart-service/` · `feat/cart-redis-cache` | Implementar `cart-service` (:8002) en `redis-cart` (`GET /health`, sesiones con TTL 24 h, CRUD y vaciado de carrito con TTL 7 días, `Dockerfile`). Integrar **cache-aside** en `catalog-service` con `redis-catalog-cache` (`TTL`, invalidación al actualizar producto, fallback a MongoDB si Redis cae). **Entrega Final:** prueba de rendimiento (100 peticiones con y sin caché, tabla, gráfica y conclusiones). |
| **Roque Martinez** | **Integración, API y Pruebas** | `feat/integration-tests` | Definir contrato de endpoints y crear Swagger/Postman (o interfaz mínima). Probar integración completa vía Nginx. **Entrega Final:** prueba de fallos (apagar contenedor y documentar respuesta controlada + recuperación), prueba de concurrencia (dos compras simultáneas del último artículo), reporte final y coordinación de video/presentación (máx. 10 min). |

---

## 2. Estrategia de Ramas y Commits en Git

- Rama principal: `main` (recibe cambios probados mediante Pull Request).
- Ramas de trabajo por módulo:
  - `feat/infra-aws` (German)
  - `feat/orders-service` (Lizbeth)
  - `feat/catalog-mongodb` (Elton)
  - `feat/cart-redis-cache` (Abraham)
  - `feat/integration-tests` (Roque)
- Convención de commits (*Conventional Commits*):
  - `feat(orders): implementa endpoint confirmar compra con transaccion ACID`
  - `feat(catalog): agrega filtros por categoria/precio y resenas`
  - `feat(cart): implementa CRUD de carrito y sesiones con TTL en Redis`
  - `test(concurrency): agrega script de compra simultanea del ultimo articulo`
- **Regla de seguridad:** antes de hacer commit verificar `git status` para asegurar que **ningún** archivo `.env`, `.pem` ni credencial de AWS esté incluido.

---

## 3. Cronograma de Entregas

| Fecha | Hito | Alcance |
|---|---|---|
| **18–20 nov (Entrega 1)** | Diseño + Infraestructura base | Arquitectura, decisiones, modelos de datos (PostgreSQL, MongoDB, Redis), reparto de tareas, repo Git y EC2 con BDs levantadas. |
| **23–27 nov (Entrega 2)** | Construcción por módulo | Los 3 microservicios funcionando por separado con `GET /health`, Swagger/Postman, infraestructura AWS levantada y evidencia de cada servicio. |
| **30 nov–2 dic (Entrega Final)** | Integración y pruebas | Comunicación completa vía API en EC2, pruebas de rendimiento, fallos y concurrencia, reporte final y video. |
| **3–4 dic** | Presentación | Demostración en vivo (máx. 10 min) con participación de todos los integrantes. |
