// Después de init.js: recalcula resumenResenas de cada producto a partir de la
// colección resenas (mismo cálculo que hace el servicio al registrar una reseña).
const d = db.getSiblingDB("tienda_catalogo");
const stats = {};
d.resenas.aggregate([
  { $group: { _id: "$productoId", promedio: { $avg: "$calificacion" }, total: { $sum: 1 } } },
]).forEach((s) => { stats[s._id] = s; });
d.productos.find({}, { productoId: 1 }).forEach((p) => {
  const s = stats[p.productoId];
  const promedio = s ? Math.round(s.promedio * 10) / 10 : 0;
  d.productos.updateOne({ _id: p._id }, {
    // en mongosh los números JS se guardan como double; total debe ser int
    $set: { resumenResenas: { promedio: promedio, total: NumberInt(s ? s.total : 0) } },
  });
  print(`[align] ${p.productoId}: promedio=${promedio} total=${s ? s.total : 0}`);
});
print(`[align] productos=${d.productos.countDocuments()} resenas=${d.resenas.countDocuments()}`);
