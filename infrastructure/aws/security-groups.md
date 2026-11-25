# Diseño de Red, VPC y Security Groups en AWS

## 1. Topología de Red (VPC)

| Recurso | Nombre / Identificador | CIDR / Configuración | Notas de Seguridad y Costos |
|---|---|---|---|
| **VPC** | `vpc-tienda-departamental` | `10.0.0.0/16` | DNS hostnames y DNS resolution habilitados |
| **Internet Gateway** | `igw-tienda` | Adjunto a `vpc-tienda-departamental` | Salida controlada para subred pública |
| **Subred Pública** | `subnet-tienda-publica` | `10.0.1.0/24` (AZ-a) | Aloja la instancia `ec2-gateway-bastion` (Nginx API + Bastión SSH) |
| **Subred Privada** | `subnet-tienda-privada` | `10.0.2.0/24` (AZ-a) | Aloja `ec2-catalog`, `ec2-cart` y `ec2-orders` (sin IP pública en modo privado estricto) |
| **Tabla de Rutas Pública** | `rtb-tienda-publica` | `10.0.0.0/16 -> local`, `0.0.0.0/0 -> igw-tienda` | Asociada únicamente a `subnet-tienda-publica` |
| **Tabla de Rutas Privada** | `rtb-tienda-privada` | `10.0.0.0/16 -> local` | **Sin ruta directa a Internet Gateway** (las BDs nunca son accesibles desde Internet) |

> **Nota sobre Costos (Capa Gratuita / AWS Academy):**
> Un *AWS NAT Gateway* tiene costo por hora (~$0.045/h) y **no** entra en la Capa Gratuita. Para instalar paquetes/Docker en las instancias de servicio sin pagar NAT Gateway, existen dos opciones aprobadas por el enunciado:
> 1. **Opción recomendada para Capa Gratuita (Modo `strict-sg`)**: Desplegar las 4 EC2 `t3.micro`/`t2.micro` en la VPC con **Security Groups estrictos** donde **solo** `sg-gateway-bastion` abre HTTP (`80`) a Internet y **ninguna instancia de base de datos abre `5432`, `27017` ni `6379` a Internet** (además cada contenedor BD hace bind a `127.0.0.1` o red privada interna).
> 2. **Modo Subred Privada Pura (`vpc-private`)**: Las 3 EC2 de servicios viven en `10.0.2.0/24` sin IP pública; durante el aprovisionamiento inicial se usa una *NAT Instance* `t3.micro` temporal (o AMI preconfigurada con Docker) que se apaga al terminar.

---

## 2. Inventario de Instancias EC2 (Capa Gratuita)

| Instancia | Tipo | Subred / IP Privada | Rol y Componentes | Security Group |
|---|---|---|---|---|
| `ec2-gateway-bastion` | `t3.micro` / `t2.micro` | Pública (`10.0.1.10`) | Nginx Reverse Proxy (API pública) + Bastión SSH | `sg-gateway-bastion` |
| `ec2-catalog` | `t3.micro` / `t2.micro` | Privada (`10.0.2.10`) | `catalog-service` (:8001) + **MongoDB 7** (:27017) + **Redis Cache** (:6379) | `sg-catalog` |
| `ec2-cart` | `t3.micro` / `t2.micro` | Privada (`10.0.2.20`) | `cart-service` (:8002) + **Redis Cart/Sessions** (:6379) | `sg-cart` |
| `ec2-orders` | `t3.micro` / `t2.micro` | Privada (`10.0.2.30`) | `orders-inventory-service` (:8003) + **PostgreSQL 16** (:5432) | `sg-orders` |

---

## 3. Reglas Exactas de Security Groups

### `sg-gateway-bastion` (Único punto de entrada público)
| Dirección | Protocolo | Puerto | Origen / Destino | Propósito |
|---|---|---|---|---|
| Inbound | TCP | `80` | `0.0.0.0/0` | Tráfico HTTP público hacia la API (Nginx) |
| Inbound | TCP | `443` | `0.0.0.0/0` | Tráfico HTTPS público (opcional TLS) |
| Inbound | TCP | `22` | `<MI_IP_PUBLICA>/32` | Acceso SSH administrativo restringido únicamente a la IP del administrador |
| Outbound | TCP | `8001` | `sg-catalog` | Proxy hacia Servicio de Catálogo |
| Outbound | TCP | `8002` | `sg-cart` | Proxy hacia Servicio de Carrito |
| Outbound | TCP | `8003` | `sg-orders` | Proxy hacia Servicio de Órdenes e Inventario |
| Outbound | TCP | `22` | `sg-catalog`, `sg-cart`, `sg-orders` | Salto SSH / Túnel desde Bastión |
| Outbound | TCP | `80, 443` | `0.0.0.0/0` | Actualizaciones del sistema / Docker Hub |

### `sg-catalog` (Catálogo + MongoDB + Redis Caché)
| Dirección | Protocolo | Puerto | Origen / Destino | Propósito |
|---|---|---|---|---|
| Inbound | TCP | `8001` | `sg-gateway-bastion` | Peticiones públicas enrutadas por Nginx |
| Inbound | TCP | `8001` | `sg-orders` | Validación de precios/productos vía API HTTP desde Órdenes |
| Inbound | TCP | `22` | `sg-gateway-bastion` | Administración y túnel SSH solo vía Bastión |
| **Bloqueado** | TCP | `27017`, `6379` | **NO EXPUESTOS** | MongoDB y Redis Cache solo escuchan en `127.0.0.1` / red Docker local de `ec2-catalog` (accesibles administrativamente únicamente vía túnel SSH desde Bastión) |

### `sg-cart` (Carrito + Redis Cart/Sessions)
| Dirección | Protocolo | Puerto | Origen / Destino | Propósito |
|---|---|---|---|---|
| Inbound | TCP | `8002` | `sg-gateway-bastion` | Peticiones públicas de carrito y sesión |
| Inbound | TCP | `8002` | `sg-orders` | Leer y vaciar carrito vía API HTTP al confirmar compra |
| Inbound | TCP | `22` | `sg-gateway-bastion` | Administración y túnel SSH solo vía Bastión |
| **Bloqueado** | TCP | `6379` | **NO EXPUESTO** | Redis Cart solo escucha en `127.0.0.1` / red Docker local de `ec2-cart` |

### `sg-orders` (Órdenes e Inventario + PostgreSQL)
| Dirección | Protocolo | Puerto | Origen / Destino | Propósito |
|---|---|---|---|---|
| Inbound | TCP | `8003` | `sg-gateway-bastion` | Peticiones públicas de checkout, órdenes e historial |
| Inbound | TCP | `22` | `sg-gateway-bastion` | Administración y túnel SSH solo vía Bastión |
| **Bloqueado** | TCP | `5432` | **NO EXPUESTO** | PostgreSQL solo escucha en `127.0.0.1` / red Docker local de `ec2-orders` |
| Outbound | TCP | `8001` | `sg-catalog` | Comunicación HTTP entre servicios |
| Outbound | TCP | `8002` | `sg-cart` | Comunicación HTTP entre servicios |

---

## 4. Acceso Administrativo por Túnel SSH (Ejemplo)

Para conectarse a PostgreSQL, MongoDB o Redis desde tu laptop sin abrir puertos a Internet:

```bash
# Túnel hacia PostgreSQL en ec2-orders pasando por el Bastión
ssh -i tienda-departamental-key.pem -J ubuntu@<IP_PUBLICA_BASTION> \
    -L 15432:127.0.0.1:5432 ubuntu@10.0.2.30

# Túnel hacia MongoDB y Redis Cache en ec2-catalog pasando por el Bastión
ssh -i tienda-departamental-key.pem -J ubuntu@<IP_PUBLICA_BASTION> \
    -L 27017:127.0.0.1:27017 -L 16379:127.0.0.1:6379 ubuntu@10.0.2.10

# Túnel hacia Redis Cart en ec2-cart pasando por el Bastión
ssh -i tienda-departamental-key.pem -J ubuntu@<IP_PUBLICA_BASTION> \
    -L 26379:127.0.0.1:6379 ubuntu@10.0.2.20
```
