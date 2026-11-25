#!/usr/bin/env bash
# ==============================================================================
# Script de Verificación — Redis (Carrito, Sesiones y Caché Cache-Aside)
# Uso:
#   REDIS_HOST=127.0.0.1 REDIS_PORT=6379 REDIS_PASSWORD=tu_pass ./databases/redis/verify.sh
# ==============================================================================
set -euo pipefail

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

if [[ -n "$REDIS_PASSWORD" ]]; then
  CLI=(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning)
else
  CLI=(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT")
fi

echo "=== 1. Health Check (PING) ==="
"${CLI[@]}" PING

echo "=== 2. Prueba de Sesión de Usuario con TTL (86400s) ==="
"${CLI[@]}" HSET session:tok-demo-001 \
  userId "11111111-1111-4111-8111-111111111111" \
  email "ana.martinez@ejemplo.com" \
  nombre "Ana Martínez"
"${CLI[@]}" EXPIRE session:tok-demo-001 86400
"${CLI[@]}" HGETALL session:tok-demo-001
echo "TTL session:tok-demo-001 -> $("${CLI[@]}" TTL session:tok-demo-001)s"

echo "=== 3. Prueba de Carrito de Compra con TTL (604800s) ==="
"${CLI[@]}" HSET cart:11111111-1111-4111-8111-111111111111 \
  REF-LG-001 '{"productoId":"prod-ref-lg-001","nombre":"Refrigerador LG Inverter 18 pies","precio":18499.00,"cantidad":1}' \
  CAM-ZARA-001 '{"productoId":"prod-cam-zara-001","nombre":"Camisa Casual Oxford Azul","precio":899.00,"cantidad":2}'
"${CLI[@]}" EXPIRE cart:11111111-1111-4111-8111-111111111111 604800
"${CLI[@]}" HGETALL cart:11111111-1111-4111-8111-111111111111
echo "TTL cart -> $("${CLI[@]}" TTL cart:11111111-1111-4111-8111-111111111111)s"

echo "=== 4. Prueba de Caché Cache-Aside + Invalidación ==="
"${CLI[@]}" SETEX catalog:product:prod-ref-lg-001 300 '{"productoId":"prod-ref-lg-001","precio":18499.00}'
echo "Cache HIT -> $("${CLI[@]}" GET catalog:product:prod-ref-lg-001)"
echo "TTL cache -> $("${CLI[@]}" TTL catalog:product:prod-ref-lg-001)s"
"${CLI[@]}" DEL catalog:product:prod-ref-lg-001
echo "Tras invalidación -> $("${CLI[@]}" EXISTS catalog:product:prod-ref-lg-001) (esperado: 0)"

echo "=== 5. Limpieza de claves de prueba ==="
"${CLI[@]}" DEL session:tok-demo-001 cart:11111111-1111-4111-8111-111111111111 >/dev/null
echo "[OK] Verificación de Redis completada."
