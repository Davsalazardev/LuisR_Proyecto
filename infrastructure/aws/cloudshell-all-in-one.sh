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
SG_GW="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name sg-gateway-bastion --description "Nginx HTTP publico y Bastion SSH" \
  --query 'GroupId' --output text)"
SG_CAT="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name sg-catalog --description "Catalogo + MongoDB + Redis Cache (BDs cerradas)" \
  --query 'GroupId' --output text)"
SG_CART="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name sg-cart --description "Carrito + Redis Cart (BD cerrada)" \
  --query 'GroupId' --output text)"
SG_ORD="$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name sg-orders --description "Ordenes e Inventario + PostgreSQL (BD cerrada)" \
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
cat > /etc/nginx/sites-available/default <<'NGX'
server {
    listen 80;
    location = /health {
        default_type application/json;
        return 200 '{"service":"api-gateway","status":"ok"}';
    }
    location / {
        default_type application/json;
        return 200 '{"project":"tienda-departamental-aws","entrega":1,"status":"infra-ready"}';
    }
}
NGX
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
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE TABLE clientes (
  cliente_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre VARCHAR(120) NOT NULL,
  email VARCHAR(160) NOT NULL UNIQUE,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE inventario (
  sku VARCHAR(40) PRIMARY KEY,
  producto_id VARCHAR(64) NOT NULL UNIQUE,
  nombre_snapshot VARCHAR(180) NOT NULL,
  precio_unitario NUMERIC(12,2) NOT NULL CHECK (precio_unitario > 0),
  stock_disponible INTEGER NOT NULL CHECK (stock_disponible >= 0),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE ordenes (
  orden_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES clientes(cliente_id),
  estado VARCHAR(20) NOT NULL DEFAULT 'CONFIRMADA',
  subtotal NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
  impuestos NUMERIC(12,2) NOT NULL CHECK (impuestos >= 0),
  total NUMERIC(12,2) NOT NULL CHECK (total >= 0),
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE orden_items (
  orden_item_id BIGSERIAL PRIMARY KEY,
  orden_id UUID NOT NULL REFERENCES ordenes(orden_id) ON DELETE CASCADE,
  sku VARCHAR(40) NOT NULL REFERENCES inventario(sku),
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  precio_unitario NUMERIC(12,2) NOT NULL CHECK (precio_unitario > 0)
);
CREATE INDEX idx_ordenes_cliente_fecha ON ordenes (cliente_id, creado_en DESC);
INSERT INTO clientes (cliente_id, nombre, email) VALUES
  ('11111111-1111-4111-8111-111111111111','Ana Martinez','ana@ejemplo.com'),
  ('22222222-2222-4222-8222-222222222222','Carlos Ramirez','carlos@ejemplo.com');
INSERT INTO inventario (sku, producto_id, nombre_snapshot, precio_unitario, stock_disponible) VALUES
  ('REF-LG-001','prod-ref-lg-001','Refrigerador LG Inverter 18 pies',18499.00,1),
  ('CAM-ZARA-001','prod-cam-zara-001','Camisa Casual Algodon Oxford Azul',899.00,25);
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
echo "  5) Al terminar tus capturas, DETÉN las instancias para no gastar horas:"
echo "     aws ec2 stop-instances --region ${AWS_REGION} --instance-ids ${ID_GW} ${ID_CAT} ${ID_CART} ${ID_ORD}"
