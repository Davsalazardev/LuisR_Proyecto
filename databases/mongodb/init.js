// ============================================================================
// Servicio de Catálogo — Esquema Documental, Validación $jsonSchema e Índices
// Motor: MongoDB 7 (mongosh)
// ============================================================================
// Ejecutar con:
//   mongosh "mongodb://catalog_admin:<PASS>@127.0.0.1:27017/tienda_catalogo?authSource=admin" databases/mongodb/init.js
// ============================================================================

const dbName = "tienda_catalogo";
const catalogDb = db.getSiblingDB(dbName);

// ----------------------------------------------------------------------------
// 1. Colección `productos` con validación estricta $jsonSchema
//    Permite atributos polimórficos dentro de `atributos` según la categoría.
// ----------------------------------------------------------------------------
const productosValidator = {
  $jsonSchema: {
    bsonType: "object",
    required: [
      "productoId",
      "sku",
      "nombre",
      "categoria",
      "marca",
      "precio",
      "moneda",
      "activo",
      "atributos",
      "resumenResenas",
      "creadoEn",
      "actualizadoEn"
    ],
    additionalProperties: false,
    properties: {
      _id: { bsonType: "objectId" },
      productoId: {
        bsonType: "string",
        minLength: 4,
        maxLength: 64,
        description: "Identificador lógico único del producto compartido vía API"
      },
      sku: {
        bsonType: "string",
        pattern: "^[A-Z0-9-]{4,40}$",
        description: "SKU en mayúsculas, números y guiones"
      },
      nombre: {
        bsonType: "string",
        minLength: 3,
        maxLength: 180
      },
      descripcion: {
        bsonType: "string",
        maxLength: 2000
      },
      categoria: {
        bsonType: "string",
        enum: ["linea_blanca", "ropa", "electronica", "calzado", "hogar"],
        description: "Categoría principal del catálogo"
      },
      subcategoria: {
        bsonType: "string",
        maxLength: 80
      },
      marca: {
        bsonType: "string",
        minLength: 1,
        maxLength: 80
      },
      precio: {
        bsonType: ["double", "decimal", "int"],
        minimum: 0.01,
        description: "Precio unitario estrictamente positivo"
      },
      moneda: {
        bsonType: "string",
        enum: ["MXN", "USD"]
      },
      activo: {
        bsonType: "bool"
      },
      imagenes: {
        bsonType: "array",
        items: {
          bsonType: "string",
          pattern: "^https?://"
        }
      },
      etiquetas: {
        bsonType: "array",
        items: { bsonType: "string" }
      },
      atributos: {
        bsonType: "object",
        minProperties: 1,
        additionalProperties: true,
        description: "Atributos variables según el tipo de producto (ej. refrigerador vs camisa)"
      },
      resumenResenas: {
        bsonType: "object",
        required: ["promedio", "total"],
        additionalProperties: false,
        properties: {
          promedio: {
            bsonType: ["double", "int"],
            minimum: 0,
            maximum: 5
          },
          total: {
            bsonType: "int",
            minimum: 0
          }
        }
      },
      creadoEn: { bsonType: "date" },
      actualizadoEn: { bsonType: "date" }
    }
  }
};

// ----------------------------------------------------------------------------
// 2. Colección `resenas` con validación estricta $jsonSchema
//    Referenciada por `productoId` para evitar crecimiento ilimitado de documentos.
// ----------------------------------------------------------------------------
const resenasValidator = {
  $jsonSchema: {
    bsonType: "object",
    required: [
      "productoId",
      "clienteId",
      "autorNombre",
      "calificacion",
      "titulo",
      "comentario",
      "compraVerificada",
      "creadoEn"
    ],
    additionalProperties: false,
    properties: {
      _id: { bsonType: "objectId" },
      productoId: {
        bsonType: "string",
        minLength: 4,
        maxLength: 64
      },
      clienteId: {
        bsonType: "string",
        minLength: 8,
        maxLength: 64
      },
      autorNombre: {
        bsonType: "string",
        minLength: 2,
        maxLength: 120
      },
      calificacion: {
        bsonType: "int",
        minimum: 1,
        maximum: 5,
        description: "Calificación entera entre 1 y 5 estrellas"
      },
      titulo: {
        bsonType: "string",
        minLength: 3,
        maxLength: 120
      },
      comentario: {
        bsonType: "string",
        minLength: 5,
        maxLength: 1500
      },
      compraVerificada: {
        bsonType: "bool"
      },
      votosUtiles: {
        bsonType: "int",
        minimum: 0
      },
      creadoEn: { bsonType: "date" }
    }
  }
};

function upsertCollection(name, validator) {
  const existing = catalogDb.getCollectionNames();
  if (!existing.includes(name)) {
    catalogDb.createCollection(name, {
      validator: validator,
      validationLevel: "strict",
      validationAction: "error"
    });
    print(`[OK] Colección '${name}' creada con validación $jsonSchema estricta.`);
  } else {
    catalogDb.runCommand({
      collMod: name,
      validator: validator,
      validationLevel: "strict",
      validationAction: "error"
    });
    print(`[OK] Validador $jsonSchema actualizado en '${name}'.`);
  }
}

upsertCollection("productos", productosValidator);
upsertCollection("resenas", resenasValidator);

// ----------------------------------------------------------------------------
// 3. Índices que respaldan todas las consultas del servicio de catálogo
// ----------------------------------------------------------------------------
catalogDb.productos.createIndex(
  { productoId: 1 },
  { name: "uq_productos_productoId", unique: true }
);
catalogDb.productos.createIndex(
  { sku: 1 },
  { name: "uq_productos_sku", unique: true }
);
catalogDb.productos.createIndex(
  { activo: 1, categoria: 1, precio: 1 },
  { name: "idx_productos_activo_categoria_precio" }
);
catalogDb.productos.createIndex(
  { activo: 1, precio: 1 },
  { name: "idx_productos_activo_precio" }
);
catalogDb.productos.createIndex(
  { nombre: "text", descripcion: "text", marca: "text" },
  { name: "idx_productos_texto", default_language: "spanish" }
);

catalogDb.resenas.createIndex(
  { productoId: 1, creadoEn: -1 },
  { name: "idx_resenas_producto_fecha" }
);
catalogDb.resenas.createIndex(
  { productoId: 1, clienteId: 1 },
  { name: "uq_resenas_producto_cliente", unique: true }
);

print("[OK] Índices creados en 'productos' y 'resenas'.");

// ----------------------------------------------------------------------------
// 4. Datos semilla heterogéneos (refrigerador, camisa, laptop, tenis + reseñas)
// ----------------------------------------------------------------------------
const ahora = new Date("2026-11-20T12:00:00Z");

const productosSeed = [
  {
    productoId: "prod-ref-lg-001",
    sku: "REF-LG-001",
    nombre: "Refrigerador LG Inverter 18 pies Acero Inoxidable",
    descripcion: "Refrigerador Top Mount con compresor Smart Inverter y enfriamiento uniforme DoorCooling+.",
    categoria: "linea_blanca",
    subcategoria: "refrigeradores",
    marca: "LG",
    precio: 18499.00,
    moneda: "MXN",
    activo: true,
    imagenes: [
      "https://cdn.tienda-ejemplo.com/productos/ref-lg-001-frente.jpg"
    ],
    etiquetas: ["ahorro-energia", "inverter", "cocina"],
    atributos: {
      capacidadPiesCubicos: 18,
      eficienciaEnergetica: "A++",
      tipoCompresor: "Smart Inverter",
      voltaje: "127V / 60Hz",
      dispensadorAgua: true,
      colorAcabado: "Acero Inoxidable",
      dimensionesCm: { alto: 178, ancho: 70, profundidad: 73 },
      garantiaMeses: 24
    },
    resumenResenas: {
      promedio: 4.5,
      total: NumberInt(2)
    },
    creadoEn: ahora,
    actualizadoEn: ahora
  },
  {
    productoId: "prod-cam-zara-001",
    sku: "CAM-ZARA-001",
    nombre: "Camisa Casual Manga Larga Algodón Oxford Azul",
    descripcion: "Camisa de corte regular confeccionada en algodón 100% Oxford transpirable.",
    categoria: "ropa",
    subcategoria: "camisas",
    marca: "Zara",
    precio: 899.00,
    moneda: "MXN",
    activo: true,
    imagenes: [
      "https://cdn.tienda-ejemplo.com/productos/cam-zara-001.jpg"
    ],
    etiquetas: ["casual", "oficina", "algodon"],
    atributos: {
      talla: "M",
      tallasDisponibles: ["S", "M", "L", "XL"],
      color: "Azul Marino",
      material: "100% Algodón Oxford",
      corte: "Regular Fit",
      genero: "Unisex",
      instruccionesLavado: "Lavar a máquina en agua fría; no usar cloro"
    },
    resumenResenas: {
      promedio: 5.0,
      total: NumberInt(1)
    },
    creadoEn: ahora,
    actualizadoEn: ahora
  },
  {
    productoId: "prod-lap-asus-001",
    sku: "LAP-ASUS-001",
    nombre: "Laptop ASUS Zenbook 14 OLED 16GB RAM 512GB SSD",
    descripcion: "Ultrabook ligera con pantalla OLED 2.8K, cuerpo de aluminio y batería de larga duración.",
    categoria: "electronica",
    subcategoria: "laptops",
    marca: "ASUS",
    precio: 21999.00,
    moneda: "MXN",
    activo: true,
    imagenes: [
      "https://cdn.tienda-ejemplo.com/productos/lap-asus-001.jpg"
    ],
    etiquetas: ["ultrabook", "oled", "trabajo"],
    atributos: {
      procesador: "Intel Core Ultra 7 155H",
      ramGb: 16,
      almacenamientoGb: 512,
      tipoAlmacenamiento: "NVMe PCIe 4.0 SSD",
      pantallaPulgadas: 14.0,
      resolucion: "2880x1800 OLED 90Hz",
      sistemaOperativo: "Windows 11 Home",
      pesoKg: 1.22
    },
    resumenResenas: {
      promedio: 0,
      total: NumberInt(0)
    },
    creadoEn: ahora,
    actualizadoEn: ahora
  },
  {
    productoId: "prod-ten-nike-001",
    sku: "TEN-NIKE-001",
    nombre: "Tenis Deportivos Running Air Zoom Negro",
    descripcion: "Calzado de alto rendimiento con amortiguación reactiva para entrenamiento diario.",
    categoria: "calzado",
    subcategoria: "deportivo",
    marca: "Nike",
    precio: 2799.00,
    moneda: "MXN",
    activo: true,
    imagenes: [
      "https://cdn.tienda-ejemplo.com/productos/ten-nike-001.jpg"
    ],
    etiquetas: ["running", "deporte"],
    atributos: {
      tallaMx: 27.5,
      color: "Negro / Blanco",
      suela: "Espuma React + Unidad Air Zoom",
      tipoPisada: "Neutra",
      impermeable: false
    },
    resumenResenas: {
      promedio: 0,
      total: NumberInt(0)
    },
    creadoEn: ahora,
    actualizadoEn: ahora
  }
];

for (const doc of productosSeed) {
  catalogDb.productos.updateOne(
    { productoId: doc.productoId },
    { $setOnInsert: doc },
    { upsert: true }
  );
}

const resenasSeed = [
  {
    productoId: "prod-ref-lg-001",
    clienteId: "11111111-1111-4111-8111-111111111111",
    autorNombre: "Ana Martínez",
    calificacion: NumberInt(5),
    titulo: "Muy silencioso y enfría rápido",
    comentario: "Lleva dos meses instalado y el consumo eléctrico bajó notablemente.",
    compraVerificada: true,
    votosUtiles: NumberInt(4),
    creadoEn: new Date("2026-11-15T18:30:00Z")
  },
  {
    productoId: "prod-ref-lg-001",
    clienteId: "22222222-2222-4222-8222-222222222222",
    autorNombre: "Carlos Ramírez",
    calificacion: NumberInt(4),
    titulo: "Excelente espacio interior",
    comentario: "Muy buen acabado en acero inoxidable; solo el dispensador podría ser más alto.",
    compraVerificada: true,
    votosUtiles: NumberInt(2),
    creadoEn: new Date("2026-11-18T10:15:00Z")
  },
  {
    productoId: "prod-cam-zara-001",
    clienteId: "11111111-1111-4111-8111-111111111111",
    autorNombre: "Ana Martínez",
    calificacion: NumberInt(5),
    titulo: "Tela fresca y talla exacta",
    comentario: "El algodón Oxford tiene muy buena caída y no se arruga fácilmente.",
    compraVerificada: true,
    votosUtiles: NumberInt(1),
    creadoEn: new Date("2026-11-19T14:00:00Z")
  }
];

for (const res of resenasSeed) {
  catalogDb.resenas.updateOne(
    { productoId: res.productoId, clienteId: res.clienteId },
    { $setOnInsert: res },
    { upsert: true }
  );
}

print(`[OK] Seed completado: ${catalogDb.productos.countDocuments()} productos, ${catalogDb.resenas.countDocuments()} reseñas.`);
