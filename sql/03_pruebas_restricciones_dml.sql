-- ============================================================================
-- ARCHIVO: 03_pruebas_restricciones_dml.sql
-- DESCRIPCIÓN: Evidencia de operaciones INSERT, UPDATE, DELETE y rechazo
--              controlado ante violaciones de CHECK, FK, UNIQUE y RESTRICT.
-- ============================================================================

-- 1. INSERT válido en tabla catálogo
INSERT INTO solardb.sitio (nombre, ubicacion, zona_horaria)
VALUES ('Sitio Prueba Temporal', 'Bloque B', 'America/Bogota');

-- 2. UPDATE válido sobre el registro recién creado
UPDATE solardb.sitio
SET ubicacion = 'Bloque B - Laboratorio de Microrredes'
WHERE nombre = 'Sitio Prueba Temporal';

-- 3. RECHAZO POR CHECK (potencia_nominal_kw <= 0) -> Error esperado [23514]
INSERT INTO solardb.inversor (id_subsistema, codigo_equipo, modelo, potencia_nominal_kw)
VALUES (1, 'INV-ERR', 'Inversor Inválido', -5.00);

-- 4. RECHAZO POR FOREIGN KEY (id_inversor = 999 inexistente) -> Error esperado [23503]
INSERT INTO solardb.lectura (id_inversor, fecha_hora)
VALUES (999, NOW());

-- 5. RECHAZO POR UNIQUE (inversor + timestamp duplicado) -> Error esperado [23505]
INSERT INTO solardb.lectura (id_inversor, fecha_hora)
SELECT id_inversor, fecha_hora FROM solardb.lectura LIMIT 1;

-- 6. RECHAZO POR ON DELETE RESTRICT (inversor con lecturas asociadas) -> Error esperado [23503]
DELETE FROM solardb.inversor WHERE id_inversor = 1;

-- 7. DELETE válido sobre registro sin dependencias hijas
DELETE FROM solardb.sitio WHERE nombre = 'Sitio Prueba Temporal';
