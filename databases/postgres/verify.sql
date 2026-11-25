-- ============================================================================
-- Script de Verificación — PostgreSQL (Entrega 1)
-- Ejecutar con:
--   psql -U orders_admin -d tienda_ordenes -f databases/postgres/verify.sql
-- ============================================================================

\echo '=== 1. Tablas creadas ==='
\dt

\echo '=== 2. Índices creados ==='
\di

\echo '=== 3. Inventario inicial ==='
SELECT sku, producto_id, precio_unitario, stock_disponible FROM inventario ORDER BY sku;

\echo '=== 4. Prueba de restricción CHECK (debe fallar al intentar stock negativo) ==='
DO $$
BEGIN
    UPDATE inventario SET stock_disponible = -1 WHERE sku = 'CAM-ZARA-001';
    RAISE EXCEPTION 'ERROR: La restricción CHECK no bloqueó el stock negativo.';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'OK: CHECK (stock_disponible >= 0) bloqueó correctamente el stock negativo.';
END;
$$;

\echo '=== 5. Prueba transaccional de compra válida + rollback si falta stock ==='
BEGIN;
    SELECT * FROM confirmar_compra(
        '11111111-1111-4111-8111-111111111111'::uuid,
        '[{"sku": "REF-LG-001", "cantidad": 1}]'::jsonb,
        'verify-test-001'
    );

    SELECT sku, stock_disponible FROM inventario WHERE sku = 'REF-LG-001';

    -- Segundo intento del mismo último artículo debe fallar con INSUFFICIENT_STOCK
    DO $$
    BEGIN
        PERFORM * FROM confirmar_compra(
            '22222222-2222-4222-8222-222222222222'::uuid,
            '[{"sku": "REF-LG-001", "cantidad": 1}]'::jsonb,
            'verify-test-002'
        );
        RAISE EXCEPTION 'ERROR: Permitió sobreventa.';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'INSUFFICIENT_STOCK%' THEN
                RAISE NOTICE 'OK: Transacción rechazada correctamente -> %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    $$;
ROLLBACK; -- Dejamos los datos semilla intactos tras la prueba

\echo '=== 6. Verificación de estado limpio tras ROLLBACK ==='
SELECT sku, stock_disponible FROM inventario WHERE sku = 'REF-LG-001';
