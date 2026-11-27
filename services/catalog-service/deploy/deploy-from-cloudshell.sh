#!/usr/bin/env bash
# ==============================================================================
# Despliega catalog-service en ec2-catalog (10.0.1.20) desde AWS CloudShell.
# Requisitos en CloudShell (los deja infrastructure/aws/cloudshell-all-in-one.sh):
#   ~/tienda-creds.txt, ~/tienda-departamental-key.pem y ~/.ssh/config (ProxyJump)
# Uso:
#   1) Subir a CloudShell el paquete catalog-service.tar.gz (raíz del repo:
#      services/catalog-service + databases/mongodb/init.js)
#   2) bash deploy-from-cloudshell.sh ~/catalog-service.tar.gz
# ==============================================================================
set -euo pipefail
PKG="${1:-$HOME/catalog-service.tar.gz}"
HOST="10.0.1.20"
source "${HOME}/tienda-creds.txt"

echo "[1/5] Copiando paquete a ec2-catalog vía Bastión..."
scp -q "$PKG" "${HOST}:/tmp/catalog-service.tar.gz"

echo "[2/5] Extrayendo y escribiendo .env (solo en la EC2, permisos 600)..."
ssh "$HOST" "sudo rm -rf /opt/tienda-src && sudo mkdir -p /opt/tienda-src && sudo tar -xzf /tmp/catalog-service.tar.gz -C /opt/tienda-src && sudo chown -R ubuntu:ubuntu /opt/tienda-src
cat > /opt/tienda-src/services/catalog-service/.env <<ENV
CATALOG_SERVICE_PORT=8001
MONGO_URI=mongodb://catalog_admin:${MONGO_PASS}@127.0.0.1:27017/tienda_catalogo?authSource=admin
MONGO_DB_NAME=tienda_catalogo
REDIS_CACHE_HOST=127.0.0.1
REDIS_CACHE_PORT=6379
REDIS_CACHE_PASSWORD=${REDIS_CACHE_PASS}
CATALOG_CACHE_TTL_PRODUCT_SECONDS=300
CATALOG_CACHE_TTL_LIST_SECONDS=120
CATALOG_CACHE_TTL_REVIEWS_SECONDS=120
ENV
chmod 600 /opt/tienda-src/services/catalog-service/.env"

echo "[3/5] Alineando MongoDB con databases/mongodb/init.js (validador, índices y semilla)..."
ssh "$HOST" "set -e; cd /opt/tienda-src
for f in services/catalog-service/deploy/align-db-pre.js databases/mongodb/init.js services/catalog-service/deploy/align-db-post.js; do
  docker cp \"\$f\" tienda-mongodb-catalog:/tmp/\$(basename \$f)
  docker exec tienda-mongodb-catalog mongosh --quiet 'mongodb://catalog_admin:${MONGO_PASS}@127.0.0.1:27017/tienda_catalogo?authSource=admin' --file /tmp/\$(basename \$f)
done"

echo "[4/5] Construyendo imagen y levantando contenedor en :8001..."
ssh "$HOST" "set -e; cd /opt/tienda-src/services/catalog-service
docker build -q -t catalog-service:1.0 .
docker rm -f catalog-service >/dev/null 2>&1 || true
docker run -d --name catalog-service --restart unless-stopped --network host --env-file .env catalog-service:1.0"

echo "[5/5] Esperando /health..."
for i in $(seq 1 30); do
  if ssh "$HOST" "curl -sf http://127.0.0.1:8001/health" 2>/dev/null; then echo; break; fi
  sleep 2
done
echo "Probar desde Internet: curl http://${GW_PUB_IP}/api/catalog/products"
