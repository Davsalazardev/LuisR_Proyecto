// Antes de aplicar databases/mongodb/init.js sobre una BD ya creada:
// borra índices con la misma clave pero distinto nombre (init.js usa nombres
// explícitos y MongoDB no permite dos índices iguales con nombre diferente).
const d = db.getSiblingDB("tienda_catalogo");

// Productos semilla creados con la versión reducida del script de Entrega 1
// (sin "descripcion"): se borran para que init.js los inserte completos.
const semilla = ["prod-ref-lg-001", "prod-cam-zara-001", "prod-lap-asus-001", "prod-ten-nike-001"];
const r = d.productos.deleteMany({ productoId: { $in: semilla }, descripcion: { $exists: false } });
if (r.deletedCount) print(`[align] ${r.deletedCount} producto(s) semilla reducidos reemplazados por la versión de init.js`);
const esperados = {
  productos: ["_id_", "uq_productos_productoId", "uq_productos_sku", "idx_productos_activo_categoria_precio",
              "idx_productos_activo_precio", "idx_productos_texto"],
  resenas: ["_id_", "idx_resenas_producto_fecha", "uq_resenas_producto_cliente"],
};
for (const [col, nombres] of Object.entries(esperados)) {
  if (!d.getCollectionNames().includes(col)) continue;
  for (const idx of d[col].getIndexes()) {
    if (!nombres.includes(idx.name)) {
      d[col].dropIndex(idx.name);
      print(`[align] índice ${col}.${idx.name} eliminado (init.js lo recrea con su nombre)`);
    }
  }
}
