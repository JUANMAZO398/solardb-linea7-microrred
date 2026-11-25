-- ============================================================================
-- ARCHIVO: 02_etl_carga_limpieza.sql
-- DESCRIPCIÓN: Carga idempotente de catálogos, limpieza física, normalización
--              3FN (formato ancho -> largo) y anonimización SHA-256 de contexto.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';

-- ============================================================================
-- 1. POBLADO JERÁRQUICO DE CATÁLOGOS
-- ============================================================================

INSERT INTO solardb.sitio (nombre, ubicacion, zona_horaria)
VALUES ('Microrred Campus OpenCEM', 'Campus Universitario', 'UTC')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO solardb.subsistema (id_sitio, codigo, descripcion)
SELECT DISTINCT
    (SELECT id_sitio FROM solardb.sitio WHERE nombre = 'Microrred Campus OpenCEM'),
    'SUB-' || inv.inverter::TEXT,
    'Subsistema híbrido independiente (solar + batería + red) asociado al inversor ' || inv.inverter::TEXT
FROM (
    SELECT inverter FROM staging.specs WHERE inverter IS NOT NULL
    UNION
    SELECT inverter FROM staging.analog_measurements WHERE inverter IS NOT NULL
) inv
ON CONFLICT (id_sitio, codigo) DO NOTHING;

INSERT INTO solardb.inversor (id_subsistema, codigo_equipo, modelo, potencia_nominal_kw, intervalo_muestreo_s)
SELECT DISTINCT ON (s.inverter)
    sub.id_subsistema,
    'INV-' || s.inverter::TEXT,
    COALESCE(TRIM(s.manufacturename), 'Hibrido') || ' SN:' || COALESCE(TRIM(s.sourcesn), s.inverter::TEXT),
    5.00,
    5
FROM staging.specs s
JOIN solardb.subsistema sub ON sub.codigo = 'SUB-' || s.inverter::TEXT
WHERE s.inverter IS NOT NULL
ORDER BY s.inverter, s.read_ts DESC
ON CONFLICT (codigo_equipo) DO NOTHING;

INSERT INTO solardb.inversor (id_subsistema, codigo_equipo, modelo, potencia_nominal_kw, intervalo_muestreo_s)
SELECT DISTINCT
    sub.id_subsistema,
    'INV-' || a.inverter::TEXT,
    'Inversor Híbrido ' || a.inverter::TEXT,
    5.00,
    5
FROM staging.analog_measurements a
JOIN solardb.subsistema sub ON sub.codigo = 'SUB-' || a.inverter::TEXT
WHERE a.inverter IS NOT NULL
ON CONFLICT (codigo_equipo) DO NOTHING;

INSERT INTO solardb.unidad_medida (simbolo, nombre)
VALUES
    ('V',   'Voltios'),
    ('A',   'Amperios'),
    ('W',   'Vatios'),
    ('VA',  'Voltamperios'),
    ('%',   'Porcentaje'),
    ('Hz',  'Hercios'),
    ('kWh', 'Kilovatios-hora'),
    ('°C',  'Grados Celsius')
ON CONFLICT (simbolo) DO NOTHING;

INSERT INTO solardb.variable_telemetria (id_unidad, codigo_origen, nombre_logico, categoria, valor_min_valido, valor_max_valido)
SELECT u.id_unidad, v.codigo_origen, v.nombre_logico, v.categoria, v.min_val, v.max_val
FROM (VALUES
    ('V',   'battvolt',             'Voltaje Banco Baterías',        'BATERIA',  0,      100),
    ('A',   'battcurr',             'Corriente Banco Baterías',      'BATERIA', -300,    300),
    ('%',   'battsoc',              'Estado de Carga Batería (SOC)', 'BATERIA',  0,      100),
    ('W',   'battchgpower',         'Potencia Carga Batería',        'BATERIA', -20000,  20000),
    ('A',   'linechgcurr',          'Corriente Carga desde Red',     'RED',      0,      200),
    ('V',   'pv1volt',              'Voltaje Arreglo Solar PV1',     'SOLAR',    0,      600),
    ('A',   'pv1curr',              'Corriente Arreglo Solar PV1',   'SOLAR',    0,      100),
    ('W',   'pv1power',             'Potencia Solar PV1',            'SOLAR',    0,      25000),
    ('V',   'outvolta',             'Voltaje Salida Fase A',         'CARGA',    0,      300),
    ('Hz',  'outfreq',              'Frecuencia Salida AC',          'CARGA',    45,     65),
    ('W',   'outsumw',              'Potencia Activa Total Carga',   'CARGA',    0,      30000),
    ('kWh', 'pvgeneratenergytoday', 'Energía Solar Generada Hoy',    'SOLAR',    0,      1000),
    ('kWh', 'usedenergytoday',      'Energía Consumida Hoy',         'CARGA',    0,      1000)
) AS v(simbolo, codigo_origen, nombre_logico, categoria, min_val, max_val)
JOIN solardb.unidad_medida u ON u.simbolo = v.simbolo
ON CONFLICT (codigo_origen) DO NOTHING;

-- ============================================================================
-- 2. CARGA IDEMPOTENTE DE CABECERAS DE LECTURA
-- ============================================================================

INSERT INTO solardb.lectura (id_inversor, fecha_hora, estado_calidad)
SELECT DISTINCT
    i.id_inversor,
    CASE
        WHEN a.read_ts > 100000000000 THEN to_timestamp(a.read_ts / 1000.0)
        ELSE to_timestamp(a.read_ts)
    END,
    'VALIDA'
FROM staging.analog_measurements a
JOIN solardb.inversor i ON i.codigo_equipo = 'INV-' || a.inverter::TEXT
WHERE a.read_ts IS NOT NULL
ON CONFLICT (id_inversor, fecha_hora) DO NOTHING;

-- ============================================================================
-- 3. NORMALIZACIÓN DE MEDICIONES ANALÓGICAS (3FN) CON REGLAS DE LIMPIEZA
-- ============================================================================

TRUNCATE TABLE solardb.medicion;
ALTER TABLE solardb.medicion SET UNLOGGED;
ALTER TABLE solardb.medicion DROP CONSTRAINT IF EXISTS medicion_pkey;

INSERT INTO solardb.medicion (id_lectura, id_variable, valor)
SELECT l.id_lectura, v.id_variable, u.val
FROM (
    SELECT DISTINCT ON (inverter, read_ts) *
    FROM staging.analog_measurements
    WHERE read_ts IS NOT NULL
    ORDER BY inverter, read_ts
) a
JOIN solardb.inversor i ON i.codigo_equipo = 'INV-' || a.inverter::TEXT
JOIN solardb.lectura l  ON l.id_inversor = i.id_inversor
   AND l.fecha_hora = CASE
       WHEN a.read_ts > 100000000000 THEN to_timestamp(a.read_ts / 1000.0)
       ELSE to_timestamp(a.read_ts)
   END
CROSS JOIN LATERAL (
    VALUES
        ('battvolt',     a.battvolt),
        ('battcurr',     a.battcurr),
        ('battsoc',      a.battsoc),
        ('battchgpower', a.battchgpower),
        ('linechgcurr',  a.linechgcurr),
        ('pv1volt',      a.pv1volt),
        ('pv1curr',      a.pv1curr),
        ('pv1power',     a.pv1power),
        ('outvolta',     a.outvolta),
        ('outfreq',      a.outfreq),
        ('outsumw',      a.outsumw)
) AS u(cod, val)
JOIN solardb.variable_telemetria v ON v.codigo_origen = u.cod
WHERE u.val IS NOT NULL
  AND u.val BETWEEN v.valor_min_valido AND v.valor_max_valido;

-- ============================================================================
-- 4. CARGA DE ESTADÍSTICAS ENERGÉTICAS (CASTEO SEGURO DESDE TEXT)
-- ============================================================================

INSERT INTO solardb.medicion (id_lectura, id_variable, valor)
SELECT l.id_lectura, v.id_variable, u.val
FROM (
    SELECT DISTINCT ON (inverter, read_ts) *
    FROM staging.statistics
    WHERE read_ts IS NOT NULL
    ORDER BY inverter, read_ts
) st
JOIN solardb.inversor i ON i.codigo_equipo = 'INV-' || st.inverter::TEXT
JOIN solardb.lectura l  ON l.id_inversor = i.id_inversor
   AND l.fecha_hora = CASE
       WHEN st.read_ts > 100000000000 THEN to_timestamp(st.read_ts / 1000.0)
       ELSE to_timestamp(st.read_ts)
   END
CROSS JOIN LATERAL (
    VALUES
        ('pvgeneratenergytoday', CASE WHEN TRIM(st.pvgeneratenergytoday) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN TRIM(st.pvgeneratenergytoday)::DOUBLE PRECISION END),
        ('usedenergytoday',      CASE WHEN TRIM(st.usedenergytoday) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN TRIM(st.usedenergytoday)::DOUBLE PRECISION END)
) AS u(cod, val)
JOIN solardb.variable_telemetria v ON v.codigo_origen = u.cod
WHERE u.val IS NOT NULL
  AND u.val BETWEEN v.valor_min_valido AND v.valor_max_valido
ON CONFLICT (id_lectura, id_variable) DO NOTHING;

ALTER TABLE solardb.medicion ADD PRIMARY KEY (id_lectura, id_variable);
ALTER TABLE solardb.medicion SET LOGGED;

-- ============================================================================
-- 5. CARGA DE CONTEXTO JSONB CON ANONIMIZACIÓN SHA-256 (LEY 1581 DE 2012)
-- ============================================================================

INSERT INTO solardb.registro_contexto (id_sitio, fecha_hora, autor_anonimo, evento_json)
SELECT
    (SELECT id_sitio FROM solardb.sitio WHERE nombre = 'Microrred Campus OpenCEM'),
    CASE
        WHEN c.recorded > 100000000000 THEN to_timestamp(c.recorded / 1000.0)
        ELSE to_timestamp(c.recorded)
    END,
    encode(digest('ctx_' || COALESCE(c.id::TEXT, '0'), 'sha256'), 'hex'),
    jsonb_build_object(
        'id_origen', c.id,
        'start_ts',  c."start",
        'end_ts',    c."end",
        'detalle',   CASE
                         WHEN TRIM(c.value) LIKE '{%' OR TRIM(c.value) LIKE '[%' THEN c.value::JSONB
                         ELSE to_jsonb(c.value)
                     END
    )
FROM staging.context c
WHERE c.recorded IS NOT NULL AND c.value IS NOT NULL
ON CONFLICT (id_sitio, fecha_hora, autor_anonimo) DO NOTHING;

VACUUM ANALYZE solardb.lectura;
VACUUM ANALYZE solardb.medicion;

-- ============================================================================
-- 6. AUDITORÍA DE REGLAS DE LIMPIEZA Y CONTEOS FINALES
-- ============================================================================

SELECT
    COUNT(*) AS filas_crudas_staging,
    COUNT(*) FILTER (WHERE read_ts IS NULL OR inverter IS NULL) AS descartadas_nulos,
    COUNT(*) - COUNT(DISTINCT (inverter, read_ts)) AS descartadas_duplicadas,
    COUNT(*) FILTER (WHERE battsoc < 0 OR battsoc > 100) AS descartadas_soc_invalido,
    COUNT(*) FILTER (WHERE outfreq < 45 OR outfreq > 65) AS descartadas_frecuencia_invalida
FROM staging.analog_measurements;

SELECT 'sitio' AS tabla, COUNT(*) AS filas FROM solardb.sitio
UNION ALL SELECT 'subsistema', COUNT(*) FROM solardb.subsistema
UNION ALL SELECT 'inversor', COUNT(*) FROM solardb.inversor
UNION ALL SELECT 'variable_telemetria', COUNT(*) FROM solardb.variable_telemetria
UNION ALL SELECT 'lectura', COUNT(*) FROM solardb.lectura
UNION ALL SELECT 'medicion', COUNT(*) FROM solardb.medicion
UNION ALL SELECT 'registro_contexto', COUNT(*) FROM solardb.registro_contexto;
