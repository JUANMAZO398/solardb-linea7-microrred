-- ============================================================================
-- ARCHIVO: 05_linea7_series_tiempo_vacios.sql
-- DESCRIPCIÓN: Consultas especializadas de la Línea 7:
--              1) Agregación por ventanas fijas (date_bin)
--              2) Detección de vacíos (LAG) y cruce con contexto JSONB
--              3) Auditoría de disponibilidad continua (generate_series)
--              4) Suavizado por ventana deslizante (ROWS BETWEEN)
--              5) Evidencia de rendimiento con EXPLAIN (ANALYZE, BUFFERS)
-- ============================================================================

-- L7-1. Agregación por ventanas fijas de 15 minutos con date_bin() e integración energética
WITH ventanas_15m AS (
    SELECT
        l.id_inversor,
        date_bin('15 minutes', l.fecha_hora, TIMESTAMPTZ '2025-01-01 00:00:00+00') AS ventana_inicio,
        COUNT(*) AS muestras,
        AVG(m.valor) AS potencia_prom_w,
        MAX(m.valor) AS potencia_pico_w
    FROM solardb.lectura l
    JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
    JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
    WHERE v.codigo_origen = 'pv1power'
    GROUP BY l.id_inversor, ventana_inicio
)
SELECT
    i.codigo_equipo,
    ventana_inicio,
    muestras,
    ROUND(potencia_prom_w::NUMERIC, 2) AS potencia_prom_w,
    ROUND(potencia_pico_w::NUMERIC, 2) AS potencia_pico_w,
    ROUND(((potencia_prom_w / 1000.0) * 0.25)::NUMERIC, 4) AS energia_ventana_kwh
FROM ventanas_15m w
JOIN solardb.inversor i ON w.id_inversor = i.id_inversor
ORDER BY ventana_inicio DESC, i.codigo_equipo
LIMIT 50;

-- L7-2. Detección de vacíos (Gaps) con LAG() y cruce con intervalos de registro_contexto
WITH saltos AS (
    SELECT
        id_inversor,
        LAG(fecha_hora) OVER (PARTITION BY id_inversor ORDER BY fecha_hora) AS inicio_vacio,
        fecha_hora AS fin_vacio,
        EXTRACT(EPOCH FROM (fecha_hora - LAG(fecha_hora) OVER (PARTITION BY id_inversor ORDER BY fecha_hora))) AS segundos_perdidos
    FROM solardb.lectura
)
SELECT
    i.codigo_equipo,
    s.inicio_vacio,
    s.fin_vacio,
    ROUND(s.segundos_perdidos::NUMERIC, 1) AS duracion_segundos,
    ROUND((s.segundos_perdidos / 60.0)::NUMERIC, 2) AS duracion_minutos,
    CASE
        WHEN s.segundos_perdidos <= 300 THEN 'MICRO-CORTE (< 5 min)'
        WHEN s.segundos_perdidos <= 3600 THEN 'INTERRUPCION MEDIA (5-60 min)'
        ELSE 'CAIDA PROLONGADA (> 1 h)'
    END AS clasificacion_vacio,
    rc.evento_json -> 'detalle' AS contexto_asociado
FROM saltos s
JOIN solardb.inversor i ON s.id_inversor = i.id_inversor
LEFT JOIN solardb.registro_contexto rc
    ON s.inicio_vacio <= to_timestamp((rc.evento_json ->> 'end_ts')::DOUBLE PRECISION)
   AND s.fin_vacio >= to_timestamp((rc.evento_json ->> 'start_ts')::DOUBLE PRECISION)
WHERE s.segundos_perdidos > 30
ORDER BY s.segundos_perdidos DESC
LIMIT 40;

-- L7-3. Auditoría de vacíos totales (apagones de telemetría) mediante grilla continua generate_series
WITH limites AS (
    SELECT
        id_inversor,
        date_trunc('hour', MIN(fecha_hora)) AS h_min,
        date_trunc('hour', MAX(fecha_hora)) AS h_max,
        intervalo_muestreo_s
    FROM solardb.lectura
    JOIN solardb.inversor USING (id_inversor)
    GROUP BY id_inversor, intervalo_muestreo_s
),
grilla AS (
    SELECT
        l.id_inversor,
        gs.hora_esperada,
        (3600 / l.intervalo_muestreo_s) AS esperadas
    FROM limites l
    CROSS JOIN LATERAL generate_series(l.h_min, l.h_max, INTERVAL '1 hour') AS gs(hora_esperada)
),
reales AS (
    SELECT id_inversor, date_trunc('hour', fecha_hora) AS hora_real, COUNT(*) AS recibidas
    FROM solardb.lectura
    GROUP BY id_inversor, hora_real
)
SELECT
    i.codigo_equipo,
    g.hora_esperada,
    g.esperadas,
    COALESCE(r.recibidas, 0) AS recibidas,
    ROUND((COALESCE(r.recibidas, 0)::NUMERIC / g.esperadas) * 100, 2) AS pct_disponibilidad
FROM grilla g
JOIN solardb.inversor i ON g.id_inversor = i.id_inversor
LEFT JOIN reales r ON g.id_inversor = r.id_inversor AND g.hora_esperada = r.hora_real
WHERE COALESCE(r.recibidas, 0) = 0
ORDER BY g.hora_esperada
LIMIT 50;

-- L7-4. Suavizado de señal (Media móvil de 5 lecturas) y derivada discreta dV/dt
SELECT
    i.codigo_equipo,
    l.fecha_hora,
    m.valor AS voltaje_bateria_v,
    ROUND(AVG(m.valor) OVER (
        PARTITION BY l.id_inversor
        ORDER BY l.fecha_hora
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    )::NUMERIC, 3) AS media_movil_5_lecturas,
    ROUND((m.valor - LAG(m.valor) OVER (
        PARTITION BY l.id_inversor
        ORDER BY l.fecha_hora
    ))::NUMERIC, 3) AS delta_voltaje_v
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen = 'battvolt'
ORDER BY l.id_inversor, l.fecha_hora
LIMIT 100;

-- L7-5. EVIDENCIA DE ÍNDICES CON EXPLAIN (ANALYZE, BUFFERS) (Requerimiento 4.E)
-- Paso A: Con índices B-Tree / BRIN activos
EXPLAIN (ANALYZE, BUFFERS)
SELECT id_inversor, COUNT(*)
FROM solardb.lectura
WHERE id_inversor = 1
  AND fecha_hora BETWEEN '2025-06-01 00:00:00+00' AND '2025-06-15 23:59:59+00'
GROUP BY id_inversor;

-- Paso B: Simulación sin índices (Seq Scan) para comparar tiempos y bloques leídos
SET enable_indexscan = OFF;
SET enable_bitmapscan = OFF;
EXPLAIN (ANALYZE, BUFFERS)
SELECT id_inversor, COUNT(*)
FROM solardb.lectura
WHERE id_inversor = 1
  AND fecha_hora BETWEEN '2025-06-01 00:00:00+00' AND '2025-06-15 23:59:59+00'
GROUP BY id_inversor;

-- Restaurar parámetros del optimizador
RESET enable_indexscan;
RESET enable_bitmapscan;
