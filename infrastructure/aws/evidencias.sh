#!/usr/bin/env bash
# ==============================================================================
# Evidencias Entrega 1 (correr en CloudShell después del despliegue).
# Conecta vía Bastión (~/.ssh/config) a las 3 EC2 de BDs y guarda cada salida en
# ~/evidencias/*.txt. Uso: bash ~/evidencias.sh
# ==============================================================================
set -uo pipefail
source "${HOME}/tienda-creds.txt"
OUT="${HOME}/evidencias"; mkdir -p "$OUT"
sep() { echo; echo "======================================================================"; echo " $*"; echo "======================================================================"; }

{
  sep "0. Gateway Nginx público (http://${GW_PUB_IP})"
  echo "\$ curl http://${GW_PUB_IP}/health"; curl -s -m 5 "http://${GW_PUB_IP}/health"; echo
  for p in catalog cart orders; do
    echo "\$ curl -i http://${GW_PUB_IP}/api/${p}/  (503 = Nginx enruta, el microservicio aún no está levantado)"
    curl -s -i -m 10 "http://${GW_PUB_IP}/api/${p}/" | head -n 1; echo
  done
} 2>&1 | tee "$OUT/00-gateway.txt"

{
  sep "1. ec2-catalog (10.0.1.20) vía Bastión: MongoDB 7 + Redis Caché"
  ssh 10.0.1.20 "hostname; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    docker exec tienda-mongodb-catalog mongosh --quiet 'mongodb://catalog_admin:${MONGO_PASS}@127.0.0.1:27017/tienda_catalogo?authSource=admin' --eval '
      print(\"Colecciones:\", JSON.stringify(db.getCollectionNames()));
      print(\"Productos:\", db.productos.countDocuments(), \"| Reseñas:\", db.resenas.countDocuments());
      print(\"Índices productos:\", JSON.stringify(db.productos.getIndexes().map(i=>i.name)));
      try { db.productos.insertOne({nombre:\"invalido\"}); print(\"ERROR: aceptó documento inválido\"); }
      catch(e) { print(\"OK \$jsonSchema rechazó documento inválido, code\", e.code); }'
    echo '--- Redis Caché'
    docker exec tienda-redis-cache redis-cli -a '${REDIS_CACHE_PASS}' --no-auth-warning PING
    docker exec tienda-redis-cache redis-cli -a '${REDIS_CACHE_PASS}' --no-auth-warning CONFIG GET maxmemory-policy"
} 2>&1 | tee "$OUT/01-catalog-mongo-redis.txt"

{
  sep "2. ec2-cart (10.0.1.30) vía Bastión: Redis Carrito/Sesiones (AOF)"
  ssh 10.0.1.30 "hostname; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    R='docker exec tienda-redis-cart redis-cli -a ${REDIS_CART_PASS} --no-auth-warning'
    \$R PING; \$R CONFIG GET appendonly
    \$R SETEX cart:demo 604800 '{\"items\":[{\"sku\":\"CAM-ZARA-001\",\"cantidad\":2}]}'
    echo -n 'TTL cart:demo = '; \$R TTL cart:demo"
} 2>&1 | tee "$OUT/02-cart-redis.txt"

{
  sep "3. ec2-orders (10.0.1.40) vía Bastión: PostgreSQL 16 (verify.sql)"
  ssh 10.0.1.40 "hostname; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
  ssh 10.0.1.40 "docker exec -i tienda-postgres-orders psql -U orders_admin -d tienda_ordenes" < "${HOME}/verify.sql"
} 2>&1 | tee "$OUT/03-orders-postgres.txt"

{
  sep "4. Prueba negativa: BDs NO accesibles desde Internet (IPs públicas)"
  for id in "$ID_CAT" "$ID_CART" "$ID_ORD"; do
    ip="$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
    for port in 27017 6379 5432; do
      if timeout 4 bash -c "</dev/tcp/${ip}/${port}" 2>/dev/null; then echo "ABIERTO ${ip}:${port}  <-- REVISAR"; else echo "cerrado ${ip}:${port}"; fi
    done
  done
  sep "5. Security Groups (reglas de entrada)"
  aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].{SG:Tags[?Key==`Name`]|[0].Value,Puertos:IpPermissions[].[FromPort,join(`,`,IpRanges[].CidrIp),join(`,`,UserIdGroupPairs[].GroupId)]}' --output yaml
} 2>&1 | tee "$OUT/04-red-y-security-groups.txt"

echo; echo "Evidencias guardadas en $OUT"
