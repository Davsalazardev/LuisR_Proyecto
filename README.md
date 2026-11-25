# Tienda Departamental en AWS

Proyecto de tienda departamental dividida en **tres microservicios independientes** desplegados en AWS EC2, donde cada base de datos resuelve el problema para el que es más adecuada:

| Servicio | Carpeta | Puerto | Base de Datos | Motor |
|---|---|---|---|---|
| **Catálogo** | [services/catalog-service/](services/catalog-service/) | `8001` | Documental + Caché | MongoDB 7 + Redis 7 (`allkeys-lru`) |
| **Carrito** | [services/cart-service/](services/cart-service/) | `8002` | Clave-Valor | Redis 7 (AOF) |
| **Órdenes e Inventario** | [services/orders-inventory-service/](services/orders-inventory-service/) | `8003` | Relacional | PostgreSQL 16 |

---

## Estructura del Repositorio

```text
.
├── .env.example                      # Variables de entorno de ejemplo (NO subir .env)
├── .gitignore                        # Bloquea .env, *.pem, credenciales y dependencias
├── docs/
│   ├── arquitectura.svg              # Diagrama de VPC, subredes, Security Groups y servicios
│   ├── modelo-relacional.svg         # Diagrama ER de PostgreSQL
│   ├── decisiones-diseno.md          # Qué dato vive en cada BD, caché, TTL y tolerancia a fallos
│   ├── reparto-equipo.md             # Roles, ramas Git y cronograma
│   └── evidencia-infraestructura.md  # Guía de despliegue en EC2 y verificación de BDs
├── databases/
│   ├── postgres/                     # init.sql (tablas, CHECK, confirmar_compra) y verify.sql
│   ├── mongodb/                      # init.js ($jsonSchema, índices, seed), verify.js y ejemplos JSON
│   └── redis/                        # estructura-claves.md, redis-cart.conf, redis-cache.conf y verify.sh
├── infrastructure/
│   ├── aws/                          # security-groups.md, provision-aws.sh y cloudshell-all-in-one.sh
│   └── ec2/                          # docker-compose.yml por instancia EC2 + Nginx Gateway
└── services/
    ├── catalog-service/              # Módulo Catálogo (Entrega 2)
    ├── cart-service/                 # Módulo Carrito y Sesiones (Entrega 2)
    └── orders-inventory-service/     # Módulo Órdenes e Inventario (Entrega 2)
```

---

## Cómo empezar (para el equipo)

1. **Clona el repositorio y crea tu rama de módulo:**
   ```bash
   git clone https://github.com/Davsalazardev/LuisR_Proyecto.git
   cd LuisR_Proyecto
   cp .env.example .env
   ```
   Edita `.env` con contraseñas locales (`.env` está ignorado en `.gitignore`).

2. **Trabaja en tu rama según tu módulo** (detalle completo en [docs/reparto-equipo.md](docs/reparto-equipo.md)):
   - `feat/infra-aws` — **German David Hernandez Castro** (Rol 1): Infraestructura AWS, Security Groups, EC2 y Nginx Gateway
   - `feat/orders-postgres` — **David Eduardo Salazar Mireles** (Rol 2): PostgreSQL + `services/orders-inventory-service/`
   - `feat/catalog-mongodb` — **Bran Elton Duque Hernandez** (Rol 3): MongoDB (`$jsonSchema` + índices) + `services/catalog-service/`
   - `feat/cart-redis-cache` — **Abraham** (Rol 4): Redis (cache-aside, TTL, invalidación) + `services/cart-service/`
   - `feat/integration-tests` — **Roque Martinez** (Rol 5): Integración API, Swagger/Postman y pruebas (rendimiento, fallos y concurrencia)

3. **Levantar las bases de datos con Docker Compose:**
   - **Catálogo (MongoDB + Redis Caché):**
     ```bash
     docker compose --env-file .env -f infrastructure/ec2/catalog/docker-compose.yml up -d
     ```
   - **Carrito (Redis Carrito/Sesiones):**
     ```bash
     docker compose --env-file .env -f infrastructure/ec2/cart/docker-compose.yml up -d
     ```
   - **Órdenes e Inventario (PostgreSQL):**
     ```bash
     docker compose --env-file .env -f infrastructure/ec2/orders/docker-compose.yml up -d
     ```

---

## Reglas del Proyecto

- **Aislamiento de bases de datos:** cada servicio accede únicamente a su propia base de datos; la comunicación entre servicios es solo por API HTTP con timeouts cortos.
- **Health check obligatorio:** cada servicio debe exponer `GET /health` y responder con error controlado si una dependencia falla.
- **Seguridad:** nunca subir archivos `.env`, llaves `.pem` ni credenciales de AWS al repositorio.
- **Costos AWS:** usar instancias `t3.micro` / `t2.micro` (Capa Gratuita) y detenerlas al terminar las pruebas.
