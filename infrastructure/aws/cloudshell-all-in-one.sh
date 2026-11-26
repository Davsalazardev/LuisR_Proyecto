#!/usr/bin/env bash
# ==============================================================================
# Despliegue Completo Entrega 1 — AWS CloudShell (Todo en Uno)
# ==============================================================================
# Crea en tu cuenta AWS (Capa Gratuita t3.micro, $0 NAT Gateway):
#   1. VPC (10.0.0.0/16), Subred Pública (10.0.1.0/24), Subred Privada (10.0.2.0/24), IGW
#   2. 4 Security Groups estrictos (puertos 5432, 27017 y 6379 CERRADOS a Internet)
#   3. Key Pair (tienda-departamental-key.pem)
#   4. 4 instancias EC2 t3.micro con Docker y las 3 BDs levantadas automáticamente:
#        - ec2-gateway-bastion (Nginx :80 + Bastión SSH)
#        - ec2-catalog         (MongoDB 7 con $jsonSchema/índices + Redis Caché)
#        - ec2-cart            (Redis Carrito/Sesiones con AOF)
#        - ec2-orders          (PostgreSQL 16 con tablas, CHECK y confirmar_compra)
# ==============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-2)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="${KEY_NAME:-tienda-departamental-key}"
PROJECT_TAG="tienda-departamental"

MY_IP="$(curl -s https://checkip.amazonaws.com)"
ADMIN_CIDR="${ADMIN_CIDR:-${MY_IP}/32}"

# Contraseñas aleatorias seguras (guardadas solo localmente en ~/tienda-creds.txt)
MONGO_PASS="$(openssl rand -hex 12)"
REDIS_CACHE_PASS="$(openssl rand -hex 12)"
REDIS_CART_PASS="$(openssl rand -hex 12)"
PG_PASS="$(openssl rand -hex 12)"

echo "======================================================================"
echo " Desplegando Entrega 1 en región: $AWS_REGION ($INSTANCE_TYPE)"
echo " Acceso SSH Bastión restringido a: $ADMIN_CIDR"
echo "======================================================================"

AMI_ID="$(aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameters[0].Value' --output text)"
echo "[1/6] AMI Ubuntu 24.04: $AMI_ID"

# Key Pair
if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair --region "$AWS_REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "${HOME}/${KEY_NAME}.pem"
  chmod 400 "${HOME}/${KEY_NAME}.pem"
  echo "[2/6] Key Pair creado en ${HOME}/${KEY_NAME}.pem"
else
  echo "[2/6] Key Pair '$KEY_NAME' ya existe (usando ${HOME}/${KEY_NAME}.pem)"
fi

# VPC, Subredes, IGW y Rutas
VPC_ID="$(aws ec2 create-vpc --region "$AWS_REGION" --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=vpc-${PROJECT_TAG}},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'Vpc.VpcId' --output text)"
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

IGW_ID="$(aws ec2 create-internet-gateway --region "$AWS_REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-${PROJECT_TAG}},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)"
aws ec2 attach-internet-gateway --region "$AWS_REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

AZ="$(aws ec2 describe-availability-zones --region "$AWS_REGION" --query 'AvailabilityZones[0].ZoneName' --output text)"

PUB_SUBNET="$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-${PROJECT_TAG}-publica},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'Subnet.SubnetId' --output text)"
aws ec2 modify-subnet-attribute --region "$AWS_REGION" --subnet-id "$PUB_SUBNET" --map-public-ip-on-launch

PRIV_SUBNET="$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --cidr-block 10.0.2.0/24 --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-${PROJECT_TAG}-privada},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'Subnet.SubnetId' --output text)"

PUB_RTB="$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-${PROJECT_TAG}-publica}]" \
  --query 'RouteTable.RouteTableId' --output text)"
aws ec2 create-route --region "$AWS_REGION" --route-table-id "$PUB_RTB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --region "$AWS_REGION" --subnet-id "$PUB_SUBNET" --route-table-id "$PUB_RTB" >/dev/null

PRIV_RTB="$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-${PROJECT_TAG}-privada}]" \
  --query 'RouteTable.RouteTableId' --output text)"
aws ec2 associate-route-table --region "$AWS_REGION" --subnet-id "$PRIV_SUBNET" --route-table-id "$PRIV_RTB" >/dev/null

echo "[3/6] VPC=$VPC_ID | Pública=$PUB_SUBNET | Privada=$PRIV_SUBNET"

# Security Groups (CERO puertos de BD expuestos a Internet)
# AWS no permite GroupName con prefijo "sg-": se usa "tienda-*" como GroupName y
# "sg-*" como etiqueta Name (es lo que se ve en la consola).
SG_GW="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name tienda-gateway-bastion --description "Nginx HTTP publico y Bastion SSH" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=sg-gateway-bastion},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'GroupId' --output text)"
SG_CAT="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name tienda-catalog --description "Catalogo + MongoDB + Redis Cache (BDs cerradas)" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=sg-catalog},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'GroupId' --output text)"
SG_CART="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name tienda-cart --description "Carrito + Redis Cart (BD cerrada)" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=sg-cart},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'GroupId' --output text)"
SG_ORD="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name tienda-orders --description "Ordenes e Inventario + PostgreSQL (BD cerrada)" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=sg-orders},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'GroupId' --output text)"

aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_GW" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_GW" --protocol tcp --port 22 --cidr "$ADMIN_CIDR" >/dev/null

aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CAT" --protocol tcp --port 8001 --source-group "$SG_GW" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CAT" --protocol tcp --port 8001 --source-group "$SG_ORD" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CAT" --protocol tcp --port 22 --source-group "$SG_GW" >/dev/null

aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CART" --protocol tcp --port 8002 --source-group "$SG_GW" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CART" --protocol tcp --port 8002 --source-group "$SG_ORD" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_CART" --protocol tcp --port 22 --source-group "$SG_GW" >/dev/null

aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ORD" --protocol tcp --port 8003 --source-group "$SG_GW" >/dev/null
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ORD" --protocol tcp --port 22 --source-group "$SG_GW" >/dev/null

echo "[4/6] Security Groups creados (27017, 6379 y 5432 bloqueados a Internet)"

# --- User-data scripts para instalar Docker y levantar cada BD al arrancar ---
mkdir -p /tmp/tienda-ud

cat > /tmp/tienda-ud/gateway.sh <<'EOF'
#!/usr/bin/env bash
set -eux
apt-get update -y && apt-get install -y nginx
# Misma configuración que infrastructure/ec2/gateway/nginx.conf
cat > /etc/nginx/sites-available/default <<'NGX'
upstream catalog_upstream {
    server 10.0.1.20:8001 max_fails=2 fail_timeout=10s;
}
upstream cart_upstream {
    server 10.0.1.30:8002 max_fails=2 fail_timeout=10s;
}
upstream orders_upstream {
    server 10.0.1.40:8003 max_fails=2 fail_timeout=10s;
}
server {
    listen 80;
    server_name _;

    proxy_connect_timeout 3s;
    proxy_send_timeout 5s;
    proxy_read_timeout 5s;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    location = /health {
        default_type application/json;
        return 200 '{"service":"api-gateway","status":"ok"}';
    }
    location /api/catalog/ {
        proxy_pass http://catalog_upstream/;
        error_page 502 503 504 = @service_unavailable;
    }
    location /api/cart/ {
        proxy_pass http://cart_upstream/;
        error_page 502 503 504 = @service_unavailable;
    }
    location /api/orders/ {
        proxy_pass http://orders_upstream/;
        error_page 502 503 504 = @service_unavailable;
    }
    location @service_unavailable {
        default_type application/json;
        return 503 '{"error":"SERVICE_UNAVAILABLE","message":"El microservicio solicitado no responde temporalmente."}';
    }
}
NGX
nginx -t
systemctl restart nginx && systemctl enable nginx
EOF

cat > /tmp/tienda-ud/catalog.sh <<EOF
#!/usr/bin/env bash
set -eux
apt-get update -y && apt-get install -y docker.io
systemctl enable --now docker
usermod -aG docker ubuntu
mkdir -p /opt/catalog
cat > /opt/catalog/init.js <<'MONGOJS'
const d = db.getSiblingDB("tienda_catalogo");
d.createCollection("productos", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["productoId","sku","nombre","categoria","marca","precio","moneda","activo","atributos","resumenResenas","creadoEn","actualizadoEn"],
      additionalProperties: false,
      properties: {
        _id: { bsonType: "objectId" },
        productoId: { bsonType: "string", minLength: 4 },
        sku: { bsonType: "string", pattern: "^[A-Z0-9-]{4,40}$" },
        nombre: { bsonType: "string", minLength: 3 },
        categoria: { bsonType: "string", enum: ["linea_blanca","ropa","electronica","calzado","hogar"] },
        marca: { bsonType: "string" },
        precio: { bsonType: ["double","decimal","int"], minimum: 0.01 },
        moneda: { bsonType: "string", enum: ["MXN","USD"] },
        activo: { bsonType: "bool" },
        atributos: { bsonType: "object", minProperties: 1, additionalProperties: true },
        resumenResenas: { bsonType: "object", required: ["promedio","total"], properties: { promedio: { bsonType: ["double","int"], minimum: 0, maximum: 5 }, total: { bsonType: "int", minimum: 0 } } },
        creadoEn: { bsonType: "date" },
        actualizadoEn: { bsonType: "date" }
      }
    }
  },
  validationLevel: "strict", validationAction: "error"
});
d.createCollection("resenas", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["productoId","clienteId","autorNombre","calificacion","titulo","comentario","compraVerificada","creadoEn"],
      additionalProperties: false,
      properties: {
        _id: { bsonType: "objectId" },
        productoId: { bsonType: "string" },
        clienteId: { bsonType: "string" },
        autorNombre: { bsonType: "string" },
        calificacion: { bsonType: "int", minimum: 1, maximum: 5 },
        titulo: { bsonType: "string" },
        comentario: { bsonType: "string" },
        compraVerificada: { bsonType: "bool" },
        creadoEn: { bsonType: "date" }
      }
    }
  },
  validationLevel: "strict", validationAction: "error"
});
d.productos.createIndex({ productoId: 1 }, { unique: true });
d.productos.createIndex({ sku: 1 }, { unique: true });
d.productos.createIndex({ activo: 1, categoria: 1, precio: 1 });
d.resenas.createIndex({ productoId: 1, creadoEn: -1 });
d.resenas.createIndex({ productoId: 1, clienteId: 1 }, { unique: true });
const now = new Date();
d.productos.insertMany([
  { productoId:"prod-ref-lg-001", sku:"REF-LG-001", nombre:"Refrigerador LG Inverter 18 pies", categoria:"linea_blanca", marca:"LG", precio:18499.0, moneda:"MXN", activo:true, atributos:{ capacidadPiesCubicos:18, eficienciaEnergetica:"A++", voltaje:"127V/60Hz" }, resumenResenas:{ promedio:4.5, total:NumberInt(1) }, creadoEn:now, actualizadoEn:now },
  { productoId:"prod-cam-zara-001", sku:"CAM-ZARA-001", nombre:"Camisa Casual Algodon Oxford Azul", categoria:"ropa", marca:"Zara", precio:899.0, moneda:"MXN", activo:true, atributos:{ talla:"M", color:"Azul Marino", material:"100% Algodon" }, resumenResenas:{ promedio:5.0, total:NumberInt(1) }, creadoEn:now, actualizadoEn:now }
]);
d.resenas.insertOne({ productoId:"prod-ref-lg-001", clienteId:"11111111-1111-4111-8111-111111111111", autorNombre:"Ana Martinez", calificacion:NumberInt(5), titulo:"Excelente", comentario:"Muy silencioso y enfria rapido.", compraVerificada:true, creadoEn:now });
MONGOJS
docker run -d --name tienda-mongodb-catalog --restart unless-stopped \
  -p 127.0.0.1:27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=catalog_admin \
  -e MONGO_INITDB_ROOT_PASSWORD='${MONGO_PASS}' \
  -e MONGO_INITDB_DATABASE=tienda_catalogo \
  -v /opt/catalog/init.js:/docker-entrypoint-initdb.d/01-init.js:ro \
  mongo:7.0
docker run -d --name tienda-redis-cache --restart unless-stopped \
  -p 127.0.0.1:6379:6379 \
  redis:7.4-alpine redis-server --requirepass '${REDIS_CACHE_PASS}' --maxmemory 128mb --maxmemory-policy allkeys-lru --save ""
EOF

cat > /tmp/tienda-ud/cart.sh <<EOF
#!/usr/bin/env bash
set -eux
apt-get update -y && apt-get install -y docker.io
systemctl enable --now docker
usermod -aG docker ubuntu
docker run -d --name tienda-redis-cart --restart unless-stopped \
  -p 127.0.0.1:6379:6379 \
  redis:7.4-alpine redis-server --requirepass '${REDIS_CART_PASS}' --appendonly yes --maxmemory 256mb --maxmemory-policy volatile-lru
EOF

cat > /tmp/tienda-ud/orders.sh <<EOF
#!/usr/bin/env bash
set -eux
apt-get update -y && apt-get install -y docker.io
systemctl enable --now docker
usermod -aG docker ubuntu
mkdir -p /opt/orders
cat > /opt/orders/init.sql <<'PGSQL'
-- Copia de databases/postgres/init.sql (esquema completo + confirmar_compra).
-- Los signos de dolar van escapados porque el heredoc exterior expande variables.
-- ============================================================================
-- Servicio de Órdenes e Inventario — Esquema Relacional (PostgreSQL 16)
-- ============================================================================
-- Reglas clave cubiertas:
--   1. Integridad referencial (PK, FK) y restricciones de dominio (CHECK).
--   2. El inventario JAMÁS puede quedar en negativo (CHECK stock_disponible >= 0).
--   3. Compra atómica dentro de una transacción con bloqueo pesimista
--      (SELECT ... FOR UPDATE ordenado por SKU para evitar deadlocks).
--   4. Historial de compras indexado por cliente y fecha descendente.
--   5. Aislamiento: producto_id es una referencia lógica al catálogo (MongoDB),
--      sin consultar directamente otra base de datos.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. Tabla: clientes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clientes (
    cliente_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          VARCHAR(120) NOT NULL,
    email           VARCHAR(160) NOT NULL UNIQUE,
    telefono        VARCHAR(25),
    direccion_envio JSONB NOT NULL DEFAULT '{}'::jsonb,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 2. Tabla: inventario
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventario (
    sku               VARCHAR(40) PRIMARY KEY,
    producto_id       VARCHAR(64) NOT NULL UNIQUE,
    nombre_snapshot   VARCHAR(180) NOT NULL,
    precio_unitario   NUMERIC(12, 2) NOT NULL CHECK (precio_unitario > 0),
    stock_disponible  INTEGER NOT NULL CHECK (stock_disponible >= 0),
    stock_minimo      INTEGER NOT NULL DEFAULT 2 CHECK (stock_minimo >= 0),
    version           INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
    actualizado_en    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 3. Tabla: ordenes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ordenes (
    orden_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id       UUID NOT NULL REFERENCES clientes(cliente_id) ON DELETE RESTRICT,
    estado           VARCHAR(20) NOT NULL DEFAULT 'CONFIRMADA'
                     CHECK (estado IN ('PENDIENTE', 'CONFIRMADA', 'CANCELADA')),
    subtotal         NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0),
    impuestos        NUMERIC(12, 2) NOT NULL CHECK (impuestos >= 0),
    total            NUMERIC(12, 2) NOT NULL CHECK (total >= 0),
    moneda           CHAR(3) NOT NULL DEFAULT 'MXN',
    idempotency_key  VARCHAR(64) UNIQUE,
    creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_ordenes_total_consistente CHECK (total = ROUND(subtotal + impuestos, 2))
);

-- ----------------------------------------------------------------------------
-- 4. Tabla: orden_items
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orden_items (
    orden_item_id    BIGSERIAL PRIMARY KEY,
    orden_id         UUID NOT NULL REFERENCES ordenes(orden_id) ON DELETE CASCADE,
    sku              VARCHAR(40) NOT NULL REFERENCES inventario(sku) ON DELETE RESTRICT,
    producto_id      VARCHAR(64) NOT NULL,
    nombre_producto  VARCHAR(180) NOT NULL,
    cantidad         INTEGER NOT NULL CHECK (cantidad > 0),
    precio_unitario  NUMERIC(12, 2) NOT NULL CHECK (precio_unitario > 0),
    subtotal_linea   NUMERIC(12, 2) GENERATED ALWAYS AS (ROUND(cantidad * precio_unitario, 2)) STORED,
    CONSTRAINT uq_orden_items_orden_sku UNIQUE (orden_id, sku)
);

-- ----------------------------------------------------------------------------
-- 5. Índices de respaldo a consultas del sistema
-- ----------------------------------------------------------------------------
-- Historial de compras de un cliente ordenado de la orden más reciente a la más antigua
CREATE INDEX IF NOT EXISTS idx_ordenes_cliente_fecha
    ON ordenes (cliente_id, creado_en DESC);

-- Búsqueda de líneas por orden
CREATE INDEX IF NOT EXISTS idx_orden_items_orden
    ON orden_items (orden_id);

-- Consultas analíticas / recomendaciones ("quienes compraron esto también compraron")
CREATE INDEX IF NOT EXISTS idx_orden_items_sku_orden
    ON orden_items (sku, orden_id);

-- Mapeo rápido desde producto_id del catálogo
CREATE INDEX IF NOT EXISTS idx_inventario_producto_id
    ON inventario (producto_id);

-- ----------------------------------------------------------------------------
-- 6. Función transaccional de confirmación de compra (concurrencia segura)
-- ----------------------------------------------------------------------------
-- Parámetro p_items: JSONB con arreglo [{"sku": "REF-LG-001", "cantidad": 1}, ...]
-- Estrategia anti-sobreventa y anti-deadlock:
--   * Bloquea las filas de inventario con FOR UPDATE ordenadas por sku.
--   * Si cualquier SKU no existe o no tiene stock suficiente, lanza una excepción
--     que revierte toda la transacción (ROLLBACK automático).
CREATE OR REPLACE FUNCTION confirmar_compra(
    p_cliente_id      UUID,
    p_items           JSONB,
    p_idempotency_key VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
    orden_id  UUID,
    subtotal  NUMERIC(12, 2),
    impuestos NUMERIC(12, 2),
    total     NUMERIC(12, 2),
    estado    VARCHAR(20)
)
LANGUAGE plpgsql
AS \$\$
DECLARE
    v_orden_id       UUID;
    v_subtotal       NUMERIC(12, 2) := 0;
    v_impuestos      NUMERIC(12, 2) := 0;
    v_total          NUMERIC(12, 2) := 0;
    v_item           RECORD;
    v_inv            RECORD;
    v_existente      RECORD;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_CART: La orden debe contener al menos un producto.';
    END IF;

    -- Idempotencia opcional para reintentos seguros de red
    IF p_idempotency_key IS NOT NULL THEN
        SELECT o.orden_id, o.subtotal, o.impuestos, o.total, o.estado
          INTO v_existente
          FROM ordenes o
         WHERE o.idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN QUERY
            SELECT v_existente.orden_id, v_existente.subtotal, v_existente.impuestos,
                   v_existente.total, v_existente.estado;
            RETURN;
        END IF;
    END IF;

    -- Verificar que el cliente exista
    IF NOT EXISTS (SELECT 1 FROM clientes c WHERE c.cliente_id = p_cliente_id) THEN
        RAISE EXCEPTION 'CLIENT_NOT_FOUND: El cliente % no existe.', p_cliente_id;
    END IF;

    -- Paso 1: Bloquear filas de inventario en orden determinístico (evita deadlocks)
    --         y validar existencias antes de insertar la orden.
    FOR v_item IN
        SELECT
            elem->>'sku' AS sku,
            SUM((elem->>'cantidad')::INTEGER) AS cantidad
        FROM jsonb_array_elements(p_items) AS elem
        GROUP BY elem->>'sku'
        ORDER BY elem->>'sku' ASC
    LOOP
        IF v_item.cantidad IS NULL OR v_item.cantidad <= 0 THEN
            RAISE EXCEPTION 'INVALID_QUANTITY: Cantidad inválida para SKU %.', v_item.sku;
        END IF;

        SELECT i.sku, i.producto_id, i.nombre_snapshot, i.precio_unitario, i.stock_disponible
          INTO v_inv
          FROM inventario i
         WHERE i.sku = v_item.sku
           FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'SKU_NOT_FOUND: El SKU % no existe en inventario.', v_item.sku;
        END IF;

        IF v_inv.stock_disponible < v_item.cantidad THEN
            RAISE EXCEPTION 'INSUFFICIENT_STOCK: Stock insuficiente para SKU % (disponible: %, solicitado: %).',
                v_item.sku, v_inv.stock_disponible, v_item.cantidad;
        END IF;

        v_subtotal := v_subtotal + ROUND(v_inv.precio_unitario * v_item.cantidad, 2);
    END LOOP;

    v_impuestos := ROUND(v_subtotal * 0.16, 2);
    v_total     := ROUND(v_subtotal + v_impuestos, 2);

    -- Paso 2: Crear la orden
    INSERT INTO ordenes (cliente_id, estado, subtotal, impuestos, total, idempotency_key)
    VALUES (p_cliente_id, 'CONFIRMADA', v_subtotal, v_impuestos, v_total, p_idempotency_key)
    RETURNING ordenes.orden_id INTO v_orden_id;

    -- Paso 3: Descontar inventario e insertar detalle de la orden
    FOR v_item IN
        SELECT
            elem->>'sku' AS sku,
            SUM((elem->>'cantidad')::INTEGER) AS cantidad
        FROM jsonb_array_elements(p_items) AS elem
        GROUP BY elem->>'sku'
        ORDER BY elem->>'sku' ASC
    LOOP
        UPDATE inventario
           SET stock_disponible = stock_disponible - v_item.cantidad,
               version          = version + 1,
               actualizado_en   = NOW()
         WHERE sku = v_item.sku
        RETURNING sku, producto_id, nombre_snapshot, precio_unitario
             INTO v_inv;

        INSERT INTO orden_items (orden_id, sku, producto_id, nombre_producto, cantidad, precio_unitario)
        VALUES (v_orden_id, v_inv.sku, v_inv.producto_id, v_inv.nombre_snapshot, v_item.cantidad, v_inv.precio_unitario);
    END LOOP;

    RETURN QUERY
    SELECT v_orden_id, v_subtotal, v_impuestos, v_total, 'CONFIRMADA'::VARCHAR(20);
END;
\$\$;

-- ----------------------------------------------------------------------------
-- 7. Datos semilla (alineados con los productos de MongoDB)
-- ----------------------------------------------------------------------------
INSERT INTO clientes (cliente_id, nombre, email, telefono, direccion_envio)
VALUES
    ('11111111-1111-4111-8111-111111111111', 'Ana Martínez López', 'ana.martinez@ejemplo.com', '+52-55-1234-5678',
     '{"calle": "Av. Reforma 250", "ciudad": "Ciudad de México", "cp": "06600", "pais": "MX"}'::jsonb),
    ('22222222-2222-4222-8222-222222222222', 'Carlos Ramírez Ruiz', 'carlos.ramirez@ejemplo.com', '+52-33-9876-5432',
     '{"calle": "Av. Vallarta 1400", "ciudad": "Guadalajara", "cp": "44160", "pais": "MX"}'::jsonb)
ON CONFLICT (email) DO NOTHING;

INSERT INTO inventario (sku, producto_id, nombre_snapshot, precio_unitario, stock_disponible, stock_minimo)
VALUES
    ('REF-LG-001',   'prod-ref-lg-001',   'Refrigerador LG Inverter 18 pies Acero Inoxidable', 18499.00, 1,  2),
    ('CAM-ZARA-001', 'prod-cam-zara-001', 'Camisa Casual Manga Larga Algodón Oxford Azul',       899.00, 25, 5),
    ('LAP-ASUS-001', 'prod-lap-asus-001', 'Laptop ASUS Zenbook 14 OLED 16GB RAM 512GB SSD',    21999.00, 6,  2),
    ('TEN-NIKE-001', 'prod-ten-nike-001', 'Tenis Deportivos Running Air Zoom Negro',            2799.00, 12, 3)
ON CONFLICT (sku) DO NOTHING;

COMMIT;
PGSQL
docker run -d --name tienda-postgres-orders --restart unless-stopped \
  -p 127.0.0.1:5432:5432 \
  -e POSTGRES_DB=tienda_ordenes \
  -e POSTGRES_USER=orders_admin \
  -e POSTGRES_PASSWORD='${PG_PASS}' \
  -v /opt/orders/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro \
  postgres:16-alpine
EOF

launch_node() {
  local name="$1" sg="$2" ip="$3" ud="$4"
  aws ec2 run-instances --region "$AWS_REGION" \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$PUB_SUBNET" \
    --security-group-ids "$sg" --private-ip-address "$ip" \
    --user-data "file://${ud}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' --output text
}

echo "[5/6] Lanzando 4 instancias EC2 (${INSTANCE_TYPE})..."
ID_GW="$(launch_node ec2-gateway-bastion "$SG_GW" 10.0.1.10 /tmp/tienda-ud/gateway.sh)"
ID_CAT="$(launch_node ec2-catalog "$SG_CAT" 10.0.1.20 /tmp/tienda-ud/catalog.sh)"
ID_CART="$(launch_node ec2-cart "$SG_CART" 10.0.1.30 /tmp/tienda-ud/cart.sh)"
ID_ORD="$(launch_node ec2-orders "$SG_ORD" 10.0.1.40 /tmp/tienda-ud/orders.sh)"

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$ID_GW" "$ID_CAT" "$ID_CART" "$ID_ORD"
GW_PUB_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$ID_GW" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

cat > "${HOME}/tienda-creds.txt" <<CREDS
AWS_REGION=${AWS_REGION}
VPC_ID=${VPC_ID}
GW_PUB_IP=${GW_PUB_IP}
ID_GW=${ID_GW}
ID_CAT=${ID_CAT}
ID_CART=${ID_CART}
ID_ORD=${ID_ORD}
MONGO_PASS=${MONGO_PASS}
REDIS_CACHE_PASS=${REDIS_CACHE_PASS}
REDIS_CART_PASS=${REDIS_CART_PASS}
PG_PASS=${PG_PASS}
CREDS
chmod 600 "${HOME}/tienda-creds.txt"

# SSH config: con "-J" la opción "-i" NO se aplica al salto, así que la llave del
# Bastión se declara aquí para que "ssh -J ubuntu@<GW> ubuntu@10.0.1.x" funcione.
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
cat >> "${HOME}/.ssh/config" <<SSHCFG

# --- tienda-departamental ---
Host tienda-bastion ${GW_PUB_IP}
  HostName ${GW_PUB_IP}
  User ubuntu
  IdentityFile ${HOME}/${KEY_NAME}.pem
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
Host 10.0.1.*
  User ubuntu
  IdentityFile ${HOME}/${KEY_NAME}.pem
  ProxyJump tienda-bastion
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
SSHCFG
chmod 600 "${HOME}/.ssh/config"

echo "======================================================================"
echo " [6/6] LISTO — INFRAESTRUCTURA CREADA EN ${AWS_REGION}"
echo "======================================================================"
echo " ec2-gateway-bastion : ${ID_GW}  (Public IP: ${GW_PUB_IP} | Priv: 10.0.1.10)"
echo " ec2-catalog         : ${ID_CAT} (Priv: 10.0.1.20)"
echo " ec2-cart            : ${ID_CART} (Priv: 10.0.1.30)"
echo " ec2-orders          : ${ID_ORD} (Priv: 10.0.1.40)"
echo " Credenciales guardadas en: ${HOME}/tienda-creds.txt"
echo "======================================================================"
echo ""
echo "Espera ~2 minutos a que Docker termine de arrancar en las EC2, y luego corre:"
echo "  1) Probar Gateway público:"
echo "     curl -s http://${GW_PUB_IP}/health"
echo ""
echo "  2) Evidencia MongoDB + Redis Cache (vía Bastión):"
echo "     ssh -o StrictHostKeyChecking=no -i ~/${KEY_NAME}.pem -J ubuntu@${GW_PUB_IP} ubuntu@10.0.1.20 \"docker ps && docker exec tienda-mongodb-catalog mongosh 'mongodb://catalog_admin:${MONGO_PASS}@127.0.0.1:27017/tienda_catalogo?authSource=admin' --eval 'db.getCollectionInfos().map(c=>c.name); db.productos.getIndexes(); db.productos.countDocuments()' && docker exec tienda-redis-cache redis-cli -a '${REDIS_CACHE_PASS}' --no-auth-warning PING\""
echo ""
echo "  3) Evidencia Redis Carrito (vía Bastión):"
echo "     ssh -o StrictHostKeyChecking=no -i ~/${KEY_NAME}.pem -J ubuntu@${GW_PUB_IP} ubuntu@10.0.1.30 \"docker ps && docker exec tienda-redis-cart redis-cli -a '${REDIS_CART_PASS}' --no-auth-warning SETEX cart:demo 604800 'ok' && docker exec tienda-redis-cart redis-cli -a '${REDIS_CART_PASS}' --no-auth-warning TTL cart:demo\""
echo ""
echo "  4) Evidencia PostgreSQL (vía Bastión):"
echo "     ssh -o StrictHostKeyChecking=no -i ~/${KEY_NAME}.pem -J ubuntu@${GW_PUB_IP} ubuntu@10.0.1.40 \"docker ps && docker exec tienda-postgres-orders psql -U orders_admin -d tienda_ordenes -c '\\dt' -c 'SELECT * FROM inventario;'\""
echo ""
echo "  4b) Evidencia confirmar_compra (sube antes databases/postgres/verify.sql a CloudShell):"
echo "     ssh ubuntu@10.0.1.40 \"docker exec -i tienda-postgres-orders psql -U orders_admin -d tienda_ordenes\" < ~/verify.sql"
echo ""
echo "  5) Al terminar tus capturas, DETÉN las instancias para no gastar horas:"
echo "     aws ec2 stop-instances --region ${AWS_REGION} --instance-ids ${ID_GW} ${ID_CAT} ${ID_CART} ${ID_ORD}"
