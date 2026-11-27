// Conexión a MongoDB (fuente de verdad del catálogo).
const { MongoClient } = require('mongodb');
const config = require('./config');

const client = new MongoClient(config.mongoUri, {
  serverSelectionTimeoutMS: config.mongoTimeoutMs,
  connectTimeoutMS: config.mongoTimeoutMs,
  socketTimeoutMS: 10000,
  maxPoolSize: 10,
});

const db = client.db(config.mongoDbName);

module.exports = {
  client,
  productos: db.collection('productos'),
  resenas: db.collection('resenas'),
  async connect() {
    await client.connect();
  },
  async ping() {
    await db.command({ ping: 1 });
  },
};
