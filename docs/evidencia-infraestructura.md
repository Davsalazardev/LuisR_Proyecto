# Guía y Evidencia de Infraestructura Funcionando en AWS EC2 (Entrega 1)

Este documento describe los pasos exactos para levantar las instancias EC2 y las bases de datos en AWS, así como las **evidencias** (capturas y salidas de terminal) que deben adjuntarse a la Entrega 1.

---

## Paso 1: Crear VPC, Security Groups e Instancias EC2 en AWS

Puedes ejecutar el script automatizado directamente en **AWS CloudShell** (dentro de la consola web de AWS en Chrome, ícono `>_` arriba a la derecha) o desde tu terminal con AWS CLI:

```bash
export AWS_REGION=us-east-1
export INSTANCE_TYPE=t3.micro    # o t2.micro si tu región/cuenta lo requiere
export ADMIN_CIDR="<TU_IP_PUBLICA>/32"

chmod +x infrastructure/aws/provision-aws.sh
./infrastructure/aws/provision-aws.sh
```

> **Alternativa en Consola Web AWS**: Si creas los recursos manualmente desde la consola EC2/VPC, replica exactamente los CIDR y puertos definidos en [infrastructure/aws/security-groups.md](../infrastructure/aws/security-groups.md).

---

## Paso 2: Instalar Docker y Levantar Cada Base de Datos en su EC2

Conectándote mediante el Bastión (`ssh -i tienda-departamental-key.pem -J ubuntu@<IP_BASTION> ubuntu@<IP_PRIVADA>`):

1. **En cada una de las 3 EC2 de servicios (`ec2-catalog`, `ec2-cart`, `ec2-orders`)**:
   ```bash
   git clone <URL_DE_TU_REPO_GIT>
   cd tienda-departamental-aws
   cp .env.example .env
   nano .env   # Colocar contraseñas seguras
   chmod +x infrastructure/ec2/setup-ec2-common.sh infrastructure/ec2/verify-all-dbs.sh
   ./infrastructure/ec2/setup-ec2-common.sh
   newgrp docker
   ```

2. **En `ec2-catalog` (MongoDB 7 + Redis Cache)**:
   ```bash
   docker compose --env-file .env -f infrastructure/ec2/catalog/docker-compose.yml up -d
   ./infrastructure/ec2/verify-all-dbs.sh catalog
   ```

3. **En `ec2-cart` (Redis Carrito y Sesiones)**:
   ```bash
   docker compose --env-file .env -f infrastructure/ec2/cart/docker-compose.yml up -d
   ./infrastructure/ec2/verify-all-dbs.sh cart
   ```

4. **En `ec2-orders` (PostgreSQL 16)**:
   ```bash
   docker compose --env-file .env -f infrastructure/ec2/orders/docker-compose.yml up -d
   ./infrastructure/ec2/verify-all-dbs.sh orders
   ```

---

## Paso 3: Checklist de Evidencias para Pegar en la Entrega 1

Adjunta las siguientes capturas/salidas una vez levantadas las instancias en tu cuenta AWS:

- [ ] **Evidencia 1 — Consola AWS EC2 (Instancias Running)**: captura mostrando las 4 instancias `t3.micro`/`t2.micro` (`ec2-gateway-bastion`, `ec2-catalog`, `ec2-cart`, `ec2-orders`) en estado `Running`.
- [ ] **Evidencia 2 — Security Groups**: captura de las reglas Inbound de `sg-catalog`, `sg-cart` y `sg-orders` demostrando que **los puertos `27017`, `6379` y `5432` NO están abiertos a `0.0.0.0/0`** y que SSH (`22`) solo permite el Bastión o `<MI_IP>/32`.
- [ ] **Evidencia 3 — MongoDB funcionando (`ec2-catalog`)**: salida de `./infrastructure/ec2/verify-all-dbs.sh catalog` mostrando:
  - Contenedores `tienda-mongodb-catalog` y `tienda-redis-cache` en estado `Up (healthy)`.
  - Validador `$jsonSchema` activo en `productos` y `resenas` (rechazando inserción inválida con `code 121`).
  - Índices creados y `explain()` usando `idx_productos_activo_categoria_precio`.
- [ ] **Evidencia 4 — Redis funcionando (`ec2-cart`)**: salida de `./databases/redis/verify.sh` mostrando `PONG`, claves `session:*`, `cart:*` y `catalog:product:*` con TTL activo e invalidación exitosa.
- [ ] **Evidencia 5 — PostgreSQL funcionando (`ec2-orders`)**: salida de `./infrastructure/ec2/verify-all-dbs.sh orders` mostrando las 4 tablas (`clientes`, `inventario`, `ordenes`, `orden_items`), el rechazo de stock negativo por `CHECK (stock_disponible >= 0)` y la transacción `confirmar_compra` rechazando la segunda compra del último artículo (`INSUFFICIENT_STOCK`).
- [ ] **Evidencia 6 — Prueba negativa de exposición pública**: comando `nc -zv -w 3 <IP_PUBLICA> 5432`, `27017` y `6379` desde fuera de AWS fallando por timeout/refused (comprueba que las BDs no son accesibles desde Internet).

---

## Recordatorio de Control de Costos al Terminar

Al terminar de tomar las capturas y pruebas de la Entrega 1:
```bash
# Detener (Stop) las instancias desde AWS CLI o Consola EC2 para no consumir horas de Capa Gratuita
aws ec2 stop-instances --region "$AWS_REGION" --instance-ids <ID_GW> <ID_CAT> <ID_CART> <ID_ORD>
```
