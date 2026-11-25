// ============================================================================
// Script de Verificación — MongoDB (Entrega 1)
// Verifica colecciones, $jsonSchema (rechazando inválidos) y uso de índices.
// ============================================================================

const catalogDb = db.getSiblingDB("tienda_catalogo");

print("=== 1. Colecciones y validadores ===");
printjson(catalogDb.getCollectionInfos().map(c => ({
  name: c.name,
  validationLevel: c.options.validationLevel,
  validationAction: c.options.validationAction,
  hasJsonSchema: Boolean(c.options.validator && c.options.validator.$jsonSchema)
})));

print("=== 2. Índices en productos ===");
printjson(catalogDb.productos.getIndexes());

print("=== 3. Índices en resenas ===");
printjson(catalogDb.resenas.getIndexes());

print("=== 4. Prueba negativa de $jsonSchema en productos (precio negativo) ===");
try {
  catalogDb.productos.insertOne({
    productoId: "prod-invalido-001",
    sku: "INV-001",
    nombre: "Producto Inválido",
    categoria: "ropa",
    marca: "Test",
    precio: -50,
    moneda: "MXN",
    activo: true,
    atributos: { talla: "M" },
    resumenResenas: { promedio: 0, total: NumberInt(0) },
    creadoEn: new Date(),
    actualizadoEn: new Date()
  });
  throw new Error("ERROR: $jsonSchema no rechazó el documento inválido en productos.");
} catch (err) {
  if (err.code === 121) {
    print("[OK] MongoDB rechazó producto con precio negativo (code 121 DocumentValidationFailure).");
  } else {
    throw err;
  }
}

print("=== 5. Prueba negativa de $jsonSchema en resenas (calificación = 8) ===");
try {
  catalogDb.resenas.insertOne({
    productoId: "prod-ref-lg-001",
    clienteId: "33333333-3333-4333-8333-333333333333",
    autorNombre: "Usuario Prueba",
    calificacion: NumberInt(8),
    titulo: "Calificación fuera de rango",
    comentario: "Esto debe fallar por superar el máximo de 5.",
    compraVerificada: false,
    creadoEn: new Date()
  });
  throw new Error("ERROR: $jsonSchema no rechazó reseña con calificación > 5.");
} catch (err) {
  if (err.code === 121) {
    print("[OK] MongoDB rechazó reseña con calificación 8 (code 121 DocumentValidationFailure).");
  } else {
    throw err;
  }
}

print("=== 6. Verificación de índice con explain() (filtrar por categoría y precio) ===");
const plan = catalogDb.productos
  .find({ activo: true, categoria: "linea_blanca", precio: { $gte: 10000, $lte: 25000 } })
  .explain("executionStats");
print("Winning plan stage:", plan.queryPlanner.winningPlan.stage);
print("Input stage:", JSON.stringify(plan.queryPlanner.winningPlan.inputStage?.indexName || plan.queryPlanner.winningPlan));
