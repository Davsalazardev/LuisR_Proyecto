#!/usr/bin/env bash
# ==============================================================================
# Recolección de Evidencia de Infraestructura Funcionando (Entrega 1)
# Ejecutar en cada EC2 correspondiente según el argumento:
#   ./infrastructure/ec2/verify-all-dbs.sh catalog
#   ./infrastructure/ec2/verify-all-dbs.sh cart
#   ./infrastructure/ec2/verify-all-dbs.sh orders
# ==============================================================================
set -euo pipefail

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Uso: $0 <catalog|cart|orders>"
  exit 1
fi

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

case "$ROLE" in
  catalog)
    echo "=== [EC2 CATALOG] Estado de contenedores ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo "=== [EC2 CATALOG] Verificación MongoDB ($jsonSchema + índices) ==="
    docker exec -i tienda-mongodb-catalog mongosh \
      "mongodb://${MONGO_INITDB_ROOT_USERNAME:-catalog_admin}:${MONGO_INITDB_ROOT_PASSWORD}@127.0.0.1:27017/tienda_catalogo?authSource=admin" \
      < databases/mongodb/verify.js
    echo "=== [EC2 CATALOG] Verificación Redis Cache ==="
    docker exec -i tienda-redis-cache redis-cli -a "${REDIS_CACHE_PASSWORD}" --no-auth-warning PING
    ;;
  cart)
    echo "=== [EC2 CART] Estado de contenedores ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo "=== [EC2 CART] Verificación Redis Cart/Sessions ==="
    docker exec -i tienda-redis-cart redis-cli -a "${REDIS_CART_PASSWORD}" --no-auth-warning PING
    ;;
  orders)
    echo "=== [EC2 ORDERS] Estado de contenedores ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo "=== [EC2 ORDERS] Verificación PostgreSQL (esquema + CHECK + transacción) ==="
    docker exec -i tienda-postgres-orders psql \
      -U "${POSTGRES_USER:-orders_admin}" \
      -d "${POSTGRES_DB:-tienda_ordenes}" \
      < databases/postgres/verify.sql
    ;;
  *)
    echo "[ERROR] Rol desconocido: $ROLE (usa catalog, cart u orders)"
    exit 1
    ;;
esac
