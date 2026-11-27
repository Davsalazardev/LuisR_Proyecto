#!/usr/bin/env bash
# Vistas compactas para capturas de pantalla. Uso: bash capturas-catalog.sh <1-4>
source ~/tienda-creds.txt
API="http://${GW_PUB_IP}/api/catalog"
J='Content-Type: application/json'
c() { # método url [data] [filtro jq]
  echo -e "\n\e[1;33m\$ curl -X $1 $2${3:+ -d '$3'}\e[0m"
  curl -s -m 10 -X "$1" -H "$J" ${3:+-d "$3"} -D /tmp/h "$2" -o /tmp/b
  echo -e "\e[1;36mHTTP $(head -1 /tmp/h | cut -d' ' -f2)  X-Cache: $(grep -i '^x-cache' /tmp/h | cut -d' ' -f2 | tr -d '\r')\e[0m"
  jq -c "${4:-.}" /tmp/b 2>/dev/null || cat /tmp/b
}
case "$1" in
1) echo "== catalog-service vía Gateway público http://${GW_PUB_IP}/api/catalog -> 10.0.1.20:8001 =="
   c GET "$API/health"
   c GET "$API/products" "" '"total: \(.total)", (.items[] | {productoId, categoria, precio, resumenResenas})'
   c GET "$API/products?categoria=linea_blanca" "" '.filtros, "total: \(.total)", (.items[] | {productoId, categoria, precio})'
   c GET "$API/products?precioMin=1000&precioMax=20000" "" '.filtros, "total: \(.total)", (.items[] | {productoId, precio})'
   c GET "$API/products?precioMin=1000&precioMax=20000" "" '"total: \(.total) (respuesta desde Redis)"'
   c GET "$API/products?categoria=ropa&precioMin=500&precioMax=1000" "" '.filtros, "total: \(.total)", (.items[] | {productoId, categoria, precio})' ;;
2) echo "== Detalle: atributos variables según el tipo de producto =="
   for p in prod-ref-lg-001 prod-cam-zara-001 prod-lap-asus-001; do
     c GET "$API/products/$p" "" '{productoId, categoria, nombre}, .atributos'
   done
   c GET "$API/products/prod-ref-lg-001" "" '"mismo detalle desde caché: \(.productoId)"'
   c GET "$API/products/no-existe-999" ;;
3) echo "== POST/PUT y rechazo de \$jsonSchema (MongoDB code 121 -> HTTP 400) =="
   ID="$(date +%H%M%S)"
   c POST "$API/products" "{\"productoId\":\"prod-lic-oster-$ID\",\"sku\":\"LIC-OSTER-$ID\",\"nombre\":\"Licuadora Oster 10 velocidades\",\"categoria\":\"hogar\",\"marca\":\"Oster\",\"precio\":1299.5,\"atributos\":{\"potenciaW\":600,\"velocidades\":10}}" '{productoId, precio, atributos, resumenResenas}'
   c PUT "$API/products/prod-lic-oster-$ID" '{"precio":1199.0}' '{productoId, precio, actualizadoEn}'
   c POST "$API/products" '{"productoId":"prod-bad-001","sku":"bad sku","nombre":"X","categoria":"juguetes","marca":"Y","precio":-10,"atributos":{}}' '.error, (.details[] | {campo, regla, valor})'
   c POST "$API/products" "{\"productoId\":\"prod-extra-$ID\",\"sku\":\"EXT-$ID\",\"nombre\":\"Campo extra\",\"categoria\":\"hogar\",\"marca\":\"T\",\"precio\":10,\"atributos\":{\"a\":1},\"campoNoPermitido\":true}" '.error, .details'
   c PUT "$API/products/prod-ref-lg-001" '{"precio":"gratis"}' '.error, .details' ;;
4) echo "== Reseñas: registrar, consultar y recalcular resumenResenas =="
   ID="$(date +%H%M%S)"
   c GET "$API/products/prod-ten-nike-001/reviews" "" '{productoId, resumenResenas, total}'
   c POST "$API/products/prod-ten-nike-001/reviews" "{\"clienteId\":\"cliente-$ID-0001\",\"autorNombre\":\"Elton Duque\",\"calificacion\":5,\"titulo\":\"Muy comodos\",\"comentario\":\"Excelente amortiguacion para correr diario.\",\"compraVerificada\":true}" '{resena: (.resena | {autorNombre, calificacion, titulo}), resumenResenas}'
   c POST "$API/products/prod-ten-nike-001/reviews" "{\"clienteId\":\"cliente-$ID-0002\",\"autorNombre\":\"Ana Martinez\",\"calificacion\":4,\"titulo\":\"Buen agarre\",\"comentario\":\"Suela firme, talla un poco justa.\"}" '{resena: (.resena | {autorNombre, calificacion, titulo}), resumenResenas}'
   c GET "$API/products/prod-ten-nike-001/reviews" "" '{resumenResenas, total}, (.items[] | {autorNombre, calificacion, titulo, creadoEn})'
   c GET "$API/products/prod-ten-nike-001" "" '{productoId, resumenResenas}'
   c POST "$API/products/prod-ten-nike-001/reviews" "{\"clienteId\":\"cliente-$ID-0003\",\"autorNombre\":\"Prueba\",\"calificacion\":8,\"titulo\":\"Fuera de rango\",\"comentario\":\"Mayor a cinco estrellas.\"}" '.error, .details'
   c POST "$API/products/prod-ten-nike-001/reviews" "{\"clienteId\":\"cliente-$ID-0001\",\"autorNombre\":\"Elton Duque\",\"calificacion\":4,\"titulo\":\"Otra vez\",\"comentario\":\"Segunda resena del mismo cliente.\"}" '.error, .details' ;;
esac
