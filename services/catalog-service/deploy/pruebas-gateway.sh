#!/usr/bin/env bash
# ==============================================================================
# Pruebas de catalog-service a través del Gateway público (Nginx -> 10.0.1.20:8001)
# Uso en CloudShell:  bash pruebas-gateway.sh [IP_GATEWAY]
# Guarda la salida en ~/evidencias-catalog/pruebas-gateway.txt
# ==============================================================================
set -uo pipefail
[[ -f "${HOME}/tienda-creds.txt" ]] && source "${HOME}/tienda-creds.txt"
GW="${1:-${GW_PUB_IP:?Indica la IP del Gateway}}"
API="http://${GW}/api/catalog"
OUT="${HOME}/evidencias-catalog"; mkdir -p "$OUT"
J='Content-Type: application/json'
RUN_ID="$(date +%H%M%S)"

step() { echo; echo "======================================================================"; echo " $*"; echo "======================================================================"; }
show() { # muestra método, URL, código HTTP, X-Cache y cuerpo (resumido con jq)
  local method="$1" url="$2" data="${3:-}" filter="${4:-.}"
  echo "\$ curl -X ${method} ${url}${data:+ -d '${data}'}"
  local resp; resp="$(curl -s -m 10 -X "$method" -H "$J" ${data:+-d "$data"} -D /tmp/h.txt "$url")"
  echo "HTTP $(head -1 /tmp/h.txt | cut -d' ' -f2) | X-Cache: $(grep -i '^x-cache' /tmp/h.txt | cut -d' ' -f2 | tr -d '\r')"
  echo "$resp" | jq "$filter" 2>/dev/null || echo "$resp"
}

{
step "1. GET /health (estado de MongoDB y Redis caché)"
show GET "$API/health"

step "2. GET /products (listado completo)"
show GET "$API/products" "" '{total, items: [.items[] | {productoId, categoria, nombre, precio, resumenResenas}]}'

step "3. Filtros: categoria=linea_blanca"
show GET "$API/products?categoria=linea_blanca" "" '{filtros, total, items: [.items[] | {productoId, categoria, precio}]}'

step "4. Filtros: precioMin=1000&precioMax=20000 (2a llamada = X-Cache HIT)"
show GET "$API/products?precioMin=1000&precioMax=20000" "" '{filtros, total, items: [.items[] | {productoId, precio}]}'
show GET "$API/products?precioMin=1000&precioMax=20000" "" '{total}'

step "5. GET /products/:productoId (atributos variables según tipo)"
show GET "$API/products/prod-ref-lg-001" "" '{productoId, categoria, atributos}'
show GET "$API/products/prod-cam-zara-001" "" '{productoId, categoria, atributos}'
show GET "$API/products/no-existe-999" ""

step "6. POST /products (alta válida) y PUT /products/:productoId"
NEW="{\"productoId\":\"prod-lic-oster-${RUN_ID}\",\"sku\":\"LIC-OSTER-${RUN_ID}\",\"nombre\":\"Licuadora Oster 10 velocidades\",\"categoria\":\"hogar\",\"marca\":\"Oster\",\"precio\":1299.5,\"atributos\":{\"potenciaW\":600,\"capacidadLitros\":1.25,\"velocidades\":10}}"
show POST "$API/products" "$NEW" '{productoId, sku, precio, atributos, resumenResenas}'
show PUT "$API/products/prod-lic-oster-${RUN_ID}" '{"precio":1199.0,"atributos":{"potenciaW":600,"capacidadLitros":1.25,"velocidades":10,"vasoVidrio":true}}' '{productoId, precio, atributos}'

step "7. Rechazo de \$jsonSchema (MongoDB code 121 -> HTTP 400)"
show POST "$API/products" '{"productoId":"prod-bad-001","sku":"bad sku","nombre":"X","categoria":"juguetes","marca":"Y","precio":-10,"atributos":{}}'
show POST "$API/products" "{\"productoId\":\"prod-extra-${RUN_ID}\",\"sku\":\"EXT-${RUN_ID}\",\"nombre\":\"Campo extra\",\"categoria\":\"hogar\",\"marca\":\"Test\",\"precio\":10,\"atributos\":{\"a\":1},\"campoNoPermitido\":true}"
show PUT "$API/products/prod-ref-lg-001" '{"precio":"gratis"}'

step "8. Reseñas: GET, POST (recalcula resumenResenas) y rechazos"
show GET "$API/products/prod-lap-asus-001/reviews" "" '{productoId, resumenResenas, total}'
show POST "$API/products/prod-lap-asus-001/reviews" "{\"clienteId\":\"cliente-${RUN_ID}-0001\",\"autorNombre\":\"Elton Duque\",\"calificacion\":4,\"titulo\":\"Muy buena pantalla\",\"comentario\":\"La pantalla OLED se ve increible y la bateria dura todo el dia.\",\"compraVerificada\":true}"
show GET "$API/products/prod-lap-asus-001/reviews" "" '{productoId, resumenResenas, total, items: [.items[] | {autorNombre, calificacion, titulo}]}'
show GET "$API/products/prod-lap-asus-001" "" '{productoId, resumenResenas}'
show POST "$API/products/prod-lap-asus-001/reviews" "{\"clienteId\":\"cliente-${RUN_ID}-0002\",\"autorNombre\":\"Prueba\",\"calificacion\":8,\"titulo\":\"Fuera de rango\",\"comentario\":\"Calificacion mayor a cinco.\"}"
show POST "$API/products/prod-lap-asus-001/reviews" "{\"clienteId\":\"cliente-${RUN_ID}-0001\",\"autorNombre\":\"Elton Duque\",\"calificacion\":5,\"titulo\":\"Duplicada\",\"comentario\":\"Mismo cliente por segunda vez.\"}"
} 2>&1 | tee "$OUT/pruebas-gateway.txt"
echo; echo "Salida guardada en $OUT/pruebas-gateway.txt"
