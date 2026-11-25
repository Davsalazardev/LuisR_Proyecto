-- ============================================================================
-- Servicio de Órdenes e Inventario — Esquema Relacional (PostgreSQL 16)
-- ============================================================================
-- Reglas clave cubiertas:
--   1. Integridad referencial (PK, FK) y restricciones de dominio (CHECK).
--   2. El inventario JAMÁS puede quedar en negativo (CHECK stock_disponible >= 0).
--   3. Compra atómica dentro de una transacción con bloqueo pesimista
--      (SELECT ... FOR UPDATE ordenado por SKU para evitar deadlocks).
--   4. Historial de compras indexado por cliente y fecha descendente.
--   5. Aislamiento: `producto_id` es una referencia lógica al catálogo (MongoDB),
--      sin consultar directamente otra base de datos.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. Tabla: clientes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clientes (
    cliente_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          VARCHAR(120) NOT NULL,
    email           VARCHAR(160) NOT NULL UNIQUE,
    telefono        VARCHAR(25),
    direccion_envio JSONB NOT NULL DEFAULT '{}'::jsonb,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 2. Tabla: inventario
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventario (
    sku               VARCHAR(40) PRIMARY KEY,
    producto_id       VARCHAR(64) NOT NULL UNIQUE,
    nombre_snapshot   VARCHAR(180) NOT NULL,
    precio_unitario   NUMERIC(12, 2) NOT NULL CHECK (precio_unitario > 0),
    stock_disponible  INTEGER NOT NULL CHECK (stock_disponible >= 0),
    stock_minimo      INTEGER NOT NULL DEFAULT 2 CHECK (stock_minimo >= 0),
    version           INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
    actualizado_en    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 3. Tabla: ordenes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ordenes (
    orden_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id       UUID NOT NULL REFERENCES clientes(cliente_id) ON DELETE RESTRICT,
    estado           VARCHAR(20) NOT NULL DEFAULT 'CONFIRMADA'
                     CHECK (estado IN ('PENDIENTE', 'CONFIRMADA', 'CANCELADA')),
    subtotal         NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0),
    impuestos        NUMERIC(12, 2) NOT NULL CHECK (impuestos >= 0),
    total            NUMERIC(12, 2) NOT NULL CHECK (total >= 0),
    moneda           CHAR(3) NOT NULL DEFAULT 'MXN',
    idempotency_key  VARCHAR(64) UNIQUE,
    creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_ordenes_total_consistente CHECK (total = ROUND(subtotal + impuestos, 2))
);

-- ----------------------------------------------------------------------------
-- 4. Tabla: orden_items
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orden_items (
    orden_item_id    BIGSERIAL PRIMARY KEY,
    orden_id         UUID NOT NULL REFERENCES ordenes(orden_id) ON DELETE CASCADE,
    sku              VARCHAR(40) NOT NULL REFERENCES inventario(sku) ON DELETE RESTRICT,
    producto_id      VARCHAR(64) NOT NULL,
    nombre_producto  VARCHAR(180) NOT NULL,
    cantidad         INTEGER NOT NULL CHECK (cantidad > 0),
    precio_unitario  NUMERIC(12, 2) NOT NULL CHECK (precio_unitario > 0),
    subtotal_linea   NUMERIC(12, 2) GENERATED ALWAYS AS (ROUND(cantidad * precio_unitario, 2)) STORED,
    CONSTRAINT uq_orden_items_orden_sku UNIQUE (orden_id, sku)
);

-- ----------------------------------------------------------------------------
-- 5. Índices de respaldo a consultas del sistema
-- ----------------------------------------------------------------------------
-- Historial de compras de un cliente ordenado de la orden más reciente a la más antigua
CREATE INDEX IF NOT EXISTS idx_ordenes_cliente_fecha
    ON ordenes (cliente_id, creado_en DESC);

-- Búsqueda de líneas por orden
CREATE INDEX IF NOT EXISTS idx_orden_items_orden
    ON orden_items (orden_id);

-- Consultas analíticas / recomendaciones ("quienes compraron esto también compraron")
CREATE INDEX IF NOT EXISTS idx_orden_items_sku_orden
    ON orden_items (sku, orden_id);

-- Mapeo rápido desde producto_id del catálogo
CREATE INDEX IF NOT EXISTS idx_inventario_producto_id
    ON inventario (producto_id);

-- ----------------------------------------------------------------------------
-- 6. Función transaccional de confirmación de compra (concurrencia segura)
-- ----------------------------------------------------------------------------
-- Parámetro p_items: JSONB con arreglo [{"sku": "REF-LG-001", "cantidad": 1}, ...]
-- Estrategia anti-sobreventa y anti-deadlock:
--   * Bloquea las filas de `inventario` con FOR UPDATE ordenadas por `sku`.
--   * Si cualquier SKU no existe o no tiene stock suficiente, lanza una excepción
--     que revierte toda la transacción (ROLLBACK automático).
CREATE OR REPLACE FUNCTION confirmar_compra(
    p_cliente_id      UUID,
    p_items           JSONB,
    p_idempotency_key VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
    orden_id  UUID,
    subtotal  NUMERIC(12, 2),
    impuestos NUMERIC(12, 2),
    total     NUMERIC(12, 2),
    estado    VARCHAR(20)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_orden_id       UUID;
    v_subtotal       NUMERIC(12, 2) := 0;
    v_impuestos      NUMERIC(12, 2) := 0;
    v_total          NUMERIC(12, 2) := 0;
    v_item           RECORD;
    v_inv            RECORD;
    v_existente      RECORD;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_CART: La orden debe contener al menos un producto.';
    END IF;

    -- Idempotencia opcional para reintentos seguros de red
    IF p_idempotency_key IS NOT NULL THEN
        SELECT o.orden_id, o.subtotal, o.impuestos, o.total, o.estado
          INTO v_existente
          FROM ordenes o
         WHERE o.idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN QUERY
            SELECT v_existente.orden_id, v_existente.subtotal, v_existente.impuestos,
                   v_existente.total, v_existente.estado;
            RETURN;
        END IF;
    END IF;

    -- Verificar que el cliente exista
    IF NOT EXISTS (SELECT 1 FROM clientes c WHERE c.cliente_id = p_cliente_id) THEN
        RAISE EXCEPTION 'CLIENT_NOT_FOUND: El cliente % no existe.', p_cliente_id;
    END IF;

    -- Paso 1: Bloquear filas de inventario en orden determinístico (evita deadlocks)
    --         y validar existencias antes de insertar la orden.
    FOR v_item IN
        SELECT
            elem->>'sku' AS sku,
            SUM((elem->>'cantidad')::INTEGER) AS cantidad
        FROM jsonb_array_elements(p_items) AS elem
        GROUP BY elem->>'sku'
        ORDER BY elem->>'sku' ASC
    LOOP
        IF v_item.cantidad IS NULL OR v_item.cantidad <= 0 THEN
            RAISE EXCEPTION 'INVALID_QUANTITY: Cantidad inválida para SKU %.', v_item.sku;
        END IF;

        SELECT i.sku, i.producto_id, i.nombre_snapshot, i.precio_unitario, i.stock_disponible
          INTO v_inv
          FROM inventario i
         WHERE i.sku = v_item.sku
           FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'SKU_NOT_FOUND: El SKU % no existe en inventario.', v_item.sku;
        END IF;

        IF v_inv.stock_disponible < v_item.cantidad THEN
            RAISE EXCEPTION 'INSUFFICIENT_STOCK: Stock insuficiente para SKU % (disponible: %, solicitado: %).',
                v_item.sku, v_inv.stock_disponible, v_item.cantidad;
        END IF;

        v_subtotal := v_subtotal + ROUND(v_inv.precio_unitario * v_item.cantidad, 2);
    END LOOP;

    v_impuestos := ROUND(v_subtotal * 0.16, 2);
    v_total     := ROUND(v_subtotal + v_impuestos, 2);

    -- Paso 2: Crear la orden
    INSERT INTO ordenes (cliente_id, estado, subtotal, impuestos, total, idempotency_key)
    VALUES (p_cliente_id, 'CONFIRMADA', v_subtotal, v_impuestos, v_total, p_idempotency_key)
    RETURNING ordenes.orden_id INTO v_orden_id;

    -- Paso 3: Descontar inventario e insertar detalle de la orden
    FOR v_item IN
        SELECT
            elem->>'sku' AS sku,
            SUM((elem->>'cantidad')::INTEGER) AS cantidad
        FROM jsonb_array_elements(p_items) AS elem
        GROUP BY elem->>'sku'
        ORDER BY elem->>'sku' ASC
    LOOP
        UPDATE inventario
           SET stock_disponible = stock_disponible - v_item.cantidad,
               version          = version + 1,
               actualizado_en   = NOW()
         WHERE sku = v_item.sku
        RETURNING sku, producto_id, nombre_snapshot, precio_unitario
             INTO v_inv;

        INSERT INTO orden_items (orden_id, sku, producto_id, nombre_producto, cantidad, precio_unitario)
        VALUES (v_orden_id, v_inv.sku, v_inv.producto_id, v_inv.nombre_snapshot, v_item.cantidad, v_inv.precio_unitario);
    END LOOP;

    RETURN QUERY
    SELECT v_orden_id, v_subtotal, v_impuestos, v_total, 'CONFIRMADA'::VARCHAR(20);
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. Datos semilla (alineados con los productos de MongoDB)
-- ----------------------------------------------------------------------------
INSERT INTO clientes (cliente_id, nombre, email, telefono, direccion_envio)
VALUES
    ('11111111-1111-4111-8111-111111111111', 'Ana Martínez López', 'ana.martinez@ejemplo.com', '+52-55-1234-5678',
     '{"calle": "Av. Reforma 250", "ciudad": "Ciudad de México", "cp": "06600", "pais": "MX"}'::jsonb),
    ('22222222-2222-4222-8222-222222222222', 'Carlos Ramírez Ruiz', 'carlos.ramirez@ejemplo.com', '+52-33-9876-5432',
     '{"calle": "Av. Vallarta 1400", "ciudad": "Guadalajara", "cp": "44160", "pais": "MX"}'::jsonb)
ON CONFLICT (email) DO NOTHING;

INSERT INTO inventario (sku, producto_id, nombre_snapshot, precio_unitario, stock_disponible, stock_minimo)
VALUES
    ('REF-LG-001',   'prod-ref-lg-001',   'Refrigerador LG Inverter 18 pies Acero Inoxidable', 18499.00, 1,  2),
    ('CAM-ZARA-001', 'prod-cam-zara-001', 'Camisa Casual Manga Larga Algodón Oxford Azul',       899.00, 25, 5),
    ('LAP-ASUS-001', 'prod-lap-asus-001', 'Laptop ASUS Zenbook 14 OLED 16GB RAM 512GB SSD',    21999.00, 6,  2),
    ('TEN-NIKE-001', 'prod-ten-nike-001', 'Tenis Deportivos Running Air Zoom Negro',            2799.00, 12, 3)
ON CONFLICT (sku) DO NOTHING;

COMMIT;
