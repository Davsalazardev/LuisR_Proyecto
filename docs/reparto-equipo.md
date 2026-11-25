# Organización del Equipo, Reparto de Tareas y Flujo Git

## 1. Reparto de Módulos (Equipo de 5 Integrantes)

**Profesor:** Luis Roberto Flores

> Cada integrante es dueño de su módulo y debe registrar **commits propios** en el repositorio Git.

| Rol | Integrante | Módulo y Responsabilidades | Rama Git | Entregables Clave |
|---|---|---|---|---|
| **Rol 1** | **German David Hernandez Castro** | **Infraestructura, Seguridad y Despliegue** | `feat/infra-aws` | VPC, subredes, Security Groups, Bastión SSH, aprovisionamiento de las 4 EC2 (`t3.micro`), Docker Compose, Nginx Gateway y control de costos AWS. |
| **Rol 2** | **David Eduardo Salazar Mireles** | **Capa Relacional (Órdenes e Inventario)** | `feat/orders-postgres` | Modelo PostgreSQL, restricciones `CHECK`, función transaccional `confirmar_compra` con `FOR UPDATE`, servicio `orders-inventory-service` (:8003) e historial de compras. |
| **Rol 3** | **Bran Elton Duque Hernandez** | **Capa Documental (Catálogo)** | `feat/catalog-mongodb` | Modelo MongoDB polimórfico, validadores `$jsonSchema` en `productos` y `resenas`, índices ESR, servicio `catalog-service` (:8001) con filtros y reseñas. |
| **Rol 4** | **Abraham** | **Capa de Caché y Carrito (Redis)** | `feat/cart-redis-cache` | Instancias Redis (`redis-cache` y `redis-cart`), patrón *cache-aside*, TTL e invalidación en catálogo, servicio `cart-service` (:8002) y prueba de rendimiento (100 peticiones con/sin caché). |
| **Rol 5** | **Roque Martinez** | **Integración, API y Pruebas** | `feat/integration-tests` | Estructura del repo, contrato OpenAPI/Swagger o colección Postman, comunicación HTTP entre servicios, health checks, prueba de fallos (apagar contenedor) y prueba de concurrencia (último artículo). |

### Adaptación para Equipos de 4 o 3 Integrantes
- **Equipo de 4 integrantes**: El **Rol 5** absorbe parte del **Rol 1** (Nginx Gateway, Docker Compose y scripts de despliegue).
- **Equipo de 3 integrantes**:
  - Integrante A: **Rol 1 + Rol 5** (Infraestructura AWS, seguridad, integración y pruebas).
  - Integrante B: **Rol 2** (PostgreSQL + `orders-inventory-service`).
  - Integrante C: **Rol 3 + Rol 4** (MongoDB + Redis + `catalog-service` + `cart-service`).

---

## 2. Estrategia de Ramas y Commits en Git

- Rama principal protegida: `main` (solo recibe merges probados vía Pull Request).
- Ramas de trabajo por módulo:
  - `feat/infra-aws` (Rol 1)
  - `feat/orders-postgres` (Rol 2)
  - `feat/catalog-mongodb` (Rol 3)
  - `feat/cart-redis-cache` (Rol 4)
  - `feat/integration-tests` (Rol 5)
- Convención de commits (*Conventional Commits*):
  - `feat(postgres): agrega esquema relacional y funcion transaccional confirmar_compra`
  - `feat(mongodb): define validadores jsonSchema e indices de catalogo y resenas`
  - `feat(redis): documenta estructura de claves TTL y scripts de verificacion`
  - `chore(infra): agrega VPC, security groups y docker-compose para EC2`
- **Regla de seguridad estricta**: Antes de cada commit verificar `git status` para asegurar que **ningún** archivo `.env`, `.pem` ni credencial de AWS esté incluido.

---

## 3. Cronograma de Entregas

| Fecha | Hito | Alcance |
|---|---|---|
| **18–20 nov (Entrega 1)** | Diseño + Infraestructura base | Arquitectura, decisiones, modelos de datos (PostgreSQL, MongoDB, Redis), reparto de tareas, repo Git y EC2 con BDs levantadas. |
| **23–27 nov (Entrega 2)** | Construcción por módulo | Los 3 microservicios funcionando por separado con `/health` y evidencia de cada uno. |
| **30 nov–2 dic (Entrega Final)** | Integración y pruebas | Comunicación completa vía API, pruebas de rendimiento, fallos y concurrencia, reporte final y video. |
| **3–4 dic** | Presentación | Demostración en vivo (máx. 10 min) con participación de todo el equipo. |
