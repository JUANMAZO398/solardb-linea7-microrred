-- ============================================================================
-- ARCHIVO: 01_ddl_esquema.sql
-- PROYECTO: SolarDB - Línea 7 (Series de Tiempo y Detección de Vacíos)
-- MOTOR: PostgreSQL 14+ | HERRAMIENTA: DBeaver
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS solardb;
CREATE SCHEMA IF NOT EXISTS staging;
SET search_path TO solardb, public;

-- ============================================================================
-- 1. CATÁLOGOS ESTRUCTURALES NORMALIZADOS (3FN)
-- ============================================================================

CREATE TABLE IF NOT EXISTS sitio (
    id_sitio        SERIAL PRIMARY KEY,
    nombre          VARCHAR(100) NOT NULL UNIQUE,
    ubicacion       VARCHAR(150) NOT NULL,
    zona_horaria    VARCHAR(50)  NOT NULL DEFAULT 'UTC'
);

CREATE TABLE IF NOT EXISTS subsistema (
    id_subsistema   SERIAL PRIMARY KEY,
    id_sitio        INT NOT NULL REFERENCES sitio(id_sitio) ON DELETE RESTRICT ON UPDATE CASCADE,
    codigo          VARCHAR(30) NOT NULL,
    descripcion     TEXT,
    CONSTRAINT uq_subsistema_sitio_codigo UNIQUE (id_sitio, codigo)
);

CREATE TABLE IF NOT EXISTS inversor (
    id_inversor          SERIAL PRIMARY KEY,
    id_subsistema        INT NOT NULL REFERENCES subsistema(id_subsistema) ON DELETE RESTRICT ON UPDATE CASCADE,
    codigo_equipo        VARCHAR(50) NOT NULL UNIQUE,
    modelo               VARCHAR(100),
    potencia_nominal_kw  NUMERIC(8,2) NOT NULL CHECK (potencia_nominal_kw > 0),
    intervalo_muestreo_s INT NOT NULL DEFAULT 5 CHECK (intervalo_muestreo_s > 0)
);

CREATE TABLE IF NOT EXISTS unidad_medida (
    id_unidad   SERIAL PRIMARY KEY,
    simbolo     VARCHAR(20) NOT NULL UNIQUE,
    nombre      VARCHAR(60) NOT NULL
);

CREATE TABLE IF NOT EXISTS variable_telemetria (
    id_variable      SERIAL PRIMARY KEY,
    id_unidad        INT NOT NULL REFERENCES unidad_medida(id_unidad) ON DELETE RESTRICT ON UPDATE CASCADE,
    codigo_origen    VARCHAR(80) NOT NULL UNIQUE,
    nombre_logico    VARCHAR(100) NOT NULL,
    categoria        VARCHAR(40) NOT NULL CHECK (categoria IN ('SOLAR', 'BATERIA', 'RED', 'CARGA', 'INVERSOR', 'AMBIENTE')),
    valor_min_valido NUMERIC(14,4),
    valor_max_valido NUMERIC(14,4),
    CONSTRAINT chk_rango_variable CHECK (valor_max_valido IS NULL OR valor_min_valido IS NULL OR valor_max_valido >= valor_min_valido)
);

-- ============================================================================
-- 2. TABLAS TRANSACCIONALES DE SERIES DE TIEMPO Y CONTEXTO (3FN)
-- ============================================================================

CREATE TABLE IF NOT EXISTS lectura (
    id_lectura      BIGSERIAL PRIMARY KEY,
    id_inversor     INT NOT NULL REFERENCES inversor(id_inversor) ON DELETE RESTRICT ON UPDATE CASCADE,
    fecha_hora      TIMESTAMPTZ NOT NULL,
    estado_calidad  VARCHAR(20) NOT NULL DEFAULT 'VALIDA' CHECK (estado_calidad IN ('VALIDA', 'ATIPICA', 'INTERPOLADA')),
    CONSTRAINT uq_lectura_inversor_ts UNIQUE (id_inversor, fecha_hora)
);

CREATE TABLE IF NOT EXISTS medicion (
    id_lectura      BIGINT NOT NULL REFERENCES lectura(id_lectura) ON DELETE CASCADE ON UPDATE CASCADE,
    id_variable     INT NOT NULL REFERENCES variable_telemetria(id_variable) ON DELETE RESTRICT ON UPDATE CASCADE,
    valor           DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (id_lectura, id_variable)
);

CREATE TABLE IF NOT EXISTS registro_contexto (
    id_contexto     BIGSERIAL PRIMARY KEY,
    id_sitio        INT NOT NULL REFERENCES sitio(id_sitio) ON DELETE RESTRICT ON UPDATE CASCADE,
    fecha_hora      TIMESTAMPTZ NOT NULL,
    autor_anonimo   VARCHAR(64) NOT NULL,
    evento_json     JSONB NOT NULL,
    CONSTRAINT uq_contexto_sitio_ts_hash UNIQUE (id_sitio, fecha_hora, autor_anonimo)
);

-- ============================================================================
-- 3. TABLAS STAGING PARA MIGRACIÓN DESDE SQLITE (UNLOGGED PARA ALTA VELOCIDAD)
-- ============================================================================

CREATE UNLOGGED TABLE IF NOT EXISTS staging.specs (
    read_ts         BIGINT,
    inverter        INT,
    machcode        INT,
    producttype     INT,
    manufacturename TEXT,
    sourcesn        TEXT,
    hwver_m1        TEXT,
    hwver_m2        TEXT,
    hwver_s1        TEXT,
    hwver_s2        TEXT,
    protocolver     TEXT,
    bmsver          TEXT
);

CREATE UNLOGGED TABLE IF NOT EXISTS staging.analog_measurements (
    read_ts             BIGINT,
    inverter            INT,
    battvolt            DOUBLE PRECISION,
    battcurr            DOUBLE PRECISION,
    battsoc             DOUBLE PRECISION,
    battchgpower        DOUBLE PRECISION,
    linechgcurr         DOUBLE PRECISION,
    pvchgcurr           DOUBLE PRECISION,
    battreserve         TEXT,
    pv1volt             DOUBLE PRECISION,
    pv1curr             DOUBLE PRECISION,
    pv1power            DOUBLE PRECISION,
    pvreserve           TEXT,
    outvolta            DOUBLE PRECISION,
    outcurra            DOUBLE PRECISION,
    outfreq             DOUBLE PRECISION,
    invcurra            DOUBLE PRECISION,
    outw_a              DOUBLE PRECISION,
    outva_a             DOUBLE PRECISION,
    loadpercenta        DOUBLE PRECISION,
    normalloadw_a       DOUBLE PRECISION,
    outsumw             DOUBLE PRECISION,
    outsumva            DOUBLE PRECISION,
    sumloadpercent      DOUBLE PRECISION,
    generatedpowerp_a   DOUBLE PRECISION
);

CREATE UNLOGGED TABLE IF NOT EXISTS staging.statistics (
    read_ts                     BIGINT,
    inverter                    INT,
    batchgenergylast7day        TEXT,
    batdischgenergylast7day     TEXT,
    linechgenergylast7day       TEXT,
    loadconsumlast7day          TEXT,
    loadconsumfromlinelast7day  TEXT,
    energyreserved0             TEXT,
    generatedacpowertoday       TEXT,
    batchgenergytoday           TEXT,
    batdischgenergytoday        TEXT,
    pvgeneratenergytoday        TEXT,
    usedenergytoday             TEXT,
    workdaytotal                TEXT,
    batchgenergytotal           TEXT,
    batdischgenergytotal        TEXT,
    pvgeneratenergytotal        TEXT,
    usedenergytotal             TEXT
);

CREATE UNLOGGED TABLE IF NOT EXISTS staging.context (
    id          BIGINT,
    recorded    BIGINT,
    "start"     BIGINT,
    "end"       BIGINT,
    value       TEXT
);

-- ============================================================================
-- 4. ÍNDICES ESPECIALIZADOS EN SERIES DE TIEMPO Y JSONB
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_lectura_inversor_ts ON solardb.lectura (id_inversor, fecha_hora);
CREATE INDEX IF NOT EXISTS idx_lectura_ts_brin ON solardb.lectura USING BRIN (fecha_hora) WITH (pages_per_range = 32);
CREATE INDEX IF NOT EXISTS idx_medicion_variable ON solardb.medicion (id_variable);
CREATE INDEX IF NOT EXISTS idx_contexto_json_gin ON solardb.registro_contexto USING GIN (evento_json);

-- ============================================================================
-- 5. VISTAS DE NEGOCIO (REQUERIMIENTO 4.E)
-- ============================================================================

CREATE OR REPLACE VIEW solardb.vw_resumen_diario_operacion AS
SELECT
    i.codigo_equipo,
    DATE(l.fecha_hora AT TIME ZONE s.zona_horaria) AS dia_operacion,
    COUNT(DISTINCT l.id_lectura) AS total_lecturas_dia,
    MIN(l.fecha_hora) AS primera_lectura,
    MAX(l.fecha_hora) AS ultima_lectura
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.subsistema sub ON i.id_subsistema = sub.id_subsistema
JOIN solardb.sitio s ON sub.id_sitio = s.id_sitio
GROUP BY i.codigo_equipo, dia_operacion;

CREATE OR REPLACE VIEW solardb.vw_salud_bateria_diaria AS
SELECT
    i.codigo_equipo,
    DATE(l.fecha_hora) AS dia,
    ROUND(MIN(m.valor)::NUMERIC, 2) AS soc_minimo_pct,
    ROUND(AVG(m.valor)::NUMERIC, 2) AS soc_promedio_pct,
    ROUND(MAX(m.valor)::NUMERIC, 2) AS soc_maximo_pct,
    COUNT(*) FILTER (WHERE m.valor < 20.0) AS lecturas_bateria_critica
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen = 'battsoc'
GROUP BY i.codigo_equipo, dia;
