-- ============================================================================
-- ARCHIVO: 04_consultas_negocio_y_jsonb.sql
-- DESCRIPCIÓN: 10 consultas SQL de negocio requeridas en la Sección 4.G
--              (JOINs, agregaciones, GROUP BY/HAVING, subconsultas y JSONB).
-- ============================================================================

-- Q1. Energía solar generada, entregada a la carga y tomada de la red por inversor, día y mes
SELECT
    i.codigo_equipo,
    DATE_TRUNC('month', l.fecha_hora)::DATE AS mes,
    DATE(l.fecha_hora) AS dia,
    ROUND((AVG(CASE WHEN v.codigo_origen = 'pv1power' THEN m.valor END) * 24 / 1000.0)::NUMERIC, 3) AS energia_solar_est_kwh,
    ROUND((AVG(CASE WHEN v.codigo_origen = 'outsumw' THEN m.valor END) * 24 / 1000.0)::NUMERIC, 3) AS energia_carga_est_kwh,
    ROUND((AVG(CASE WHEN v.codigo_origen = 'linechgcurr' THEN m.valor * 120.0 END) * 24 / 1000.0)::NUMERIC, 3) AS energia_red_est_kwh
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen IN ('pv1power', 'outsumw', 'linechgcurr')
GROUP BY i.codigo_equipo, mes, dia
ORDER BY i.codigo_equipo, dia;

-- Q2. Hora del día con mayor generación solar promedio, por inversor y por mes
WITH promedio_horario AS (
    SELECT
        i.codigo_equipo,
        DATE_TRUNC('month', l.fecha_hora)::DATE AS mes,
        EXTRACT(HOUR FROM l.fecha_hora) AS hora_dia,
        AVG(m.valor) AS potencia_solar_prom_w,
        RANK() OVER (PARTITION BY i.codigo_equipo, DATE_TRUNC('month', l.fecha_hora) ORDER BY AVG(m.valor) DESC) AS rn
    FROM solardb.lectura l
    JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
    JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
    JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
    WHERE v.codigo_origen = 'pv1power'
    GROUP BY i.codigo_equipo, mes, hora_dia
)
SELECT codigo_equipo, mes, hora_dia AS hora_pico, ROUND(potencia_solar_prom_w::NUMERIC, 2) AS potencia_prom_w
FROM promedio_horario
WHERE rn = 1
ORDER BY mes, codigo_equipo;

-- Q3. Comparación entre los dos inversores en un mismo periodo diario
SELECT
    DATE(l.fecha_hora) AS dia,
    ROUND(AVG(CASE WHEN i.codigo_equipo = 'INV-0' AND v.codigo_origen = 'pv1power' THEN m.valor END)::NUMERIC, 2) AS solar_w_inv0,
    ROUND(AVG(CASE WHEN i.codigo_equipo = 'INV-1' AND v.codigo_origen = 'pv1power' THEN m.valor END)::NUMERIC, 2) AS solar_w_inv1,
    ROUND(AVG(CASE WHEN i.codigo_equipo = 'INV-0' AND v.codigo_origen = 'battsoc' THEN m.valor END)::NUMERIC, 2) AS soc_prom_inv0,
    ROUND(AVG(CASE WHEN i.codigo_equipo = 'INV-1' AND v.codigo_origen = 'battsoc' THEN m.valor END)::NUMERIC, 2) AS soc_prom_inv1
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen IN ('pv1power', 'battsoc')
GROUP BY dia
ORDER BY dia
LIMIT 30;

-- Q4. Número de lecturas con batería por debajo del umbral crítico (< 20% SOC) por día
SELECT
    i.codigo_equipo,
    DATE(l.fecha_hora) AS dia,
    COUNT(*) AS lecturas_bateria_baja,
    ROUND(MIN(m.valor)::NUMERIC, 2) AS soc_minimo_alcanzado
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen = 'battsoc'
  AND m.valor < 20.0
GROUP BY i.codigo_equipo, dia
HAVING COUNT(*) > 0
ORDER BY lecturas_bateria_baja DESC;

-- Q5. Días con datos incompletos y porcentaje de lecturas recibidas frente a las esperadas
SELECT
    i.codigo_equipo,
    DATE(l.fecha_hora) AS dia,
    COUNT(*) AS lecturas_recibidas,
    (86400 / i.intervalo_muestreo_s) AS lecturas_esperadas,
    ROUND((COUNT(*)::NUMERIC / (86400 / i.intervalo_muestreo_s)) * 100, 2) AS pct_recibido
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
GROUP BY i.codigo_equipo, i.intervalo_muestreo_s, dia
HAVING COUNT(*) < (86400 / i.intervalo_muestreo_s)
ORDER BY pct_recibido ASC;

-- Q6. Consulta sobre registros de contexto con operadores nativos JSONB (->>, ->, ?)
SELECT
    id_contexto,
    fecha_hora,
    LEFT(autor_anonimo, 12) || '...' AS operador_hash,
    evento_json ->> 'id_origen' AS id_evento_origen,
    evento_json -> 'detalle' AS contenido_json,
    jsonb_typeof(evento_json -> 'detalle') AS tipo_nodo_detalle
FROM solardb.registro_contexto
WHERE evento_json ? 'detalle'
  AND (evento_json ->> 'start_ts') IS NOT NULL
ORDER BY fecha_hora DESC
LIMIT 25;

-- Q7. Días con alta demanda eléctrica (> 80% de la capacidad nominal del inversor)
SELECT
    i.codigo_equipo,
    DATE(l.fecha_hora) AS dia,
    COUNT(*) AS eventos_alta_carga,
    ROUND(MAX(m.valor)::NUMERIC, 2) AS pico_demanda_w
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen = 'outsumw'
  AND m.valor > (i.potencia_nominal_kw * 1000 * 0.80)
GROUP BY i.codigo_equipo, dia
ORDER BY eventos_alta_carga DESC;

-- Q8. Estabilidad de frecuencia AC (mínimo, promedio, máximo y desviación estándar)
SELECT
    i.codigo_equipo,
    ROUND(MIN(m.valor)::NUMERIC, 3) AS freq_min_hz,
    ROUND(AVG(m.valor)::NUMERIC, 3) AS freq_prom_hz,
    ROUND(MAX(m.valor)::NUMERIC, 3) AS freq_max_hz,
    ROUND(STDDEV(m.valor)::NUMERIC, 4) AS desviacion_estandar
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen = 'outfreq'
GROUP BY i.codigo_equipo;

-- Q9. Subconsulta escalar: Días con mayor número de lecturas de voltaje de batería bajo el promedio histórico
SELECT
    i.codigo_equipo,
    DATE(l.fecha_hora) AS dia,
    COUNT(*) AS lecturas_bajo_promedio
FROM solardb.lectura l
JOIN solardb.inversor i ON l.id_inversor = i.id_inversor
JOIN solardb.medicion m ON l.id_lectura = m.id_lectura
JOIN solardb.variable_telemetria v ON m.id_variable = v.id_variable
WHERE v.codigo_origen = 'battvolt'
  AND m.valor < (
      SELECT AVG(m2.valor)
      FROM solardb.medicion m2
      WHERE m2.id_variable = v.id_variable
  )
GROUP BY i.codigo_equipo, dia
ORDER BY lecturas_bajo_promedio DESC
LIMIT 15;

-- Q10. Auditoría de cobertura de variables mediante LEFT JOIN
SELECT
    v.codigo_origen,
    v.nombre_logico,
    u.simbolo AS unidad,
    COUNT(m.id_lectura) AS total_mediciones_registradas
FROM solardb.variable_telemetria v
JOIN solardb.unidad_medida u ON v.id_unidad = u.id_unidad
LEFT JOIN solardb.medicion m ON v.id_variable = m.id_variable
GROUP BY v.codigo_origen, v.nombre_logico, u.simbolo
ORDER BY total_mediciones_registradas ASC;
