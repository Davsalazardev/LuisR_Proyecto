// Errores HTTP con formato JSON uniforme: { error, message, details? }
class HttpError extends Error {
  constructor(status, error, message, details) {
    super(message);
    this.status = status;
    this.error = error;
    this.details = details;
  }
}

const badRequest = (message, details) => new HttpError(400, 'BAD_REQUEST', message, details);
const notFound = (message) => new HttpError(404, 'NOT_FOUND', message);
const conflict = (message, details) => new HttpError(409, 'CONFLICT', message, details);

/** Resume errInfo de MongoDB (code 121) en una lista legible de reglas incumplidas. */
function summarizeSchemaErrors(errInfo) {
  const out = [];
  const join = (path, name) => (path ? `${path}.${name}` : name);
  const walk = (node, path) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach((n) => walk(n, path)); return; }
    if (node.propertiesNotSatisfied) {
      node.propertiesNotSatisfied.forEach((p) => walk(p.details, join(path, p.propertyName)));
    } else if (node.schemaRulesNotSatisfied) {
      walk(node.schemaRulesNotSatisfied, path);
    } else if (node.details) {
      walk(node.details, path);
    } else if (node.operatorName) {
      const item = { regla: node.operatorName };
      if (path) item.campo = path;
      if (node.missingProperties) item.faltan = node.missingProperties;
      if (node.additionalProperties) item.noPermitidos = node.additionalProperties;
      if (!item.faltan && !item.noPermitidos && node.specifiedAs) item.esperado = node.specifiedAs;
      if (node.reason) item.motivo = node.reason;
      if (node.consideredValue !== undefined) item.valor = node.consideredValue;
      out.push(item);
    }
  };
  walk(errInfo && errInfo.details, '');
  return out;
}

/** Traduce errores conocidos de MongoDB a HttpError. */
function fromMongo(err) {
  if (err && err.code === 121) {
    return new HttpError(400, 'SCHEMA_VALIDATION_FAILED',
      'MongoDB rechazó el documento: no cumple el $jsonSchema de la colección (code 121).',
      summarizeSchemaErrors(err.errInfo));
  }
  if (err && err.code === 11000) {
    return conflict('Ya existe un documento con ese valor único.', err.keyValue);
  }
  if (err && /MongoServerSelectionError|MongoNetworkError|MongoNotConnectedError/.test(err.name)) {
    return new HttpError(503, 'DATABASE_UNAVAILABLE', 'MongoDB no responde temporalmente.');
  }
  return null;
}

module.exports = { HttpError, badRequest, notFound, conflict, fromMongo };
