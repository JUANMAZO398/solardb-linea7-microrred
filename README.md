# SolarDB — Línea 7: Series de Tiempo, Agregación por Ventanas y Detección de Vacíos en la Telemetría

Proyecto correspondiente al **Taller 6 — Bases de Datos I (Grupo 811, Semestre 2026-2)** de la **Institución Universitaria Pascual Bravo** (Docente: Ramiro Grisales Montoya).

## 1. Descripción del Proyecto
Diseño, normalización hasta Tercera Forma Normal (3FN), implementación en **PostgreSQL**, carga masiva (> 2.9 millones de lecturas) desde **DBeaver** y análisis analítico sobre la telemetría real de una microrred híbrida (solar + batería + red pública) del dataset **OpenCEM v1.0.0**.

### Línea de Profundización Elegida: Línea 7
Enfoque especializado en el tratamiento de series de tiempo de alta frecuencia:
- **Agregación por ventanas fijas (`date_bin`)** para integración energética (kWh) a partir de potencia instantánea (W).
- **Detección de vacíos (*gaps*)** mediante funciones de ventana (`LAG()`) y clasificación por severidad de interrupción Modbus/RS485.
- **Auditoría de disponibilidad continua** mediante grillas temporales generadas con `generate_series()`.
- **Suavizado de señales** por media móvil deslizante (`ROWS BETWEEN`) y derivada discreta.
- **Correlación de vacíos con registros de contexto (`JSONB`)** anonimizados bajo la **Ley 1581 de 2012**.

## 2. Estructura del Repositorio
```text
solardb-linea7-microrred/
├── README.md
├── .gitignore
├── docs/
│   └── diagrama_er.png
└── sql/
    ├── 01_ddl_esquema.sql                 # Creación del esquema 3FN, restricciones, índices BRIN/B-Tree/GIN y vistas
    ├── 02_etl_carga_limpieza.sql           # Poblado de catálogos y migración idempotente desde staging
    ├── 03_pruebas_restricciones_dml.sql    # Validación de integridad referencial, CHECK, UNIQUE y RESTRICT
    ├── 04_consultas_negocio_y_jsonb.sql    # 10 consultas de negocio requeridas (JOIN, agregaciones, JSONB)
    └── 05_linea7_series_tiempo_vacios.sql  # Consultas especializadas de la Línea 7 y evidencia EXPLAIN ANALYZE
```

## 3. Descarga y Verificación de los Datos Fuente
Los datos crudos no se incluyen en este repositorio. Deben descargarse desde el registro oficial de Zenodo (`DOI: 10.5281/zenodo.21436223`):
1. Descargar `opencem-v1.0.0.sqlite.zst`, `opencem-v1.0.0-support.zip` y `opencem-v1.0.0-SHA256SUMS.txt`.
2. Verificar integridad y descomprimir:
   ```bash
   sha256sum -c opencem-v1.0.0-SHA256SUMS.txt
   zstd -d opencem-v1.0.0.sqlite.zst -o opencem-v1.0.0.sqlite
   ```

## 4. Cómo Reproducir la Base de Datos desde Cero en DBeaver
1. Crear una base de datos vacía en PostgreSQL (ej. `solardb_opencem`).
2. Ejecutar `sql/01_ddl_esquema.sql` para crear el esquema `solardb`, las tablas normalizadas, índices y vistas.
3. Conectar `opencem-v1.0.0.sqlite` en DBeaver y exportar las tablas `specs`, `analog_measurements`, `statistics` y `context` hacia el esquema `staging` en PostgreSQL (con *Commit size* = `25000`).
4. Ejecutar `sql/02_etl_carga_limpieza.sql` para limpiar, deduplicar, anonimizar contextos (SHA-256) y poblar el modelo 3FN.
5. Ejecutar `sql/03_pruebas_restricciones_dml.sql`, `sql/04_consultas_negocio_y_jsonb.sql` y `sql/05_linea7_series_tiempo_vacios.sql`.

## 5. Cita Obligatoria del Dataset
> Bartels, T. S., Wu, R., Lu, X., Chen, Y., Lu, Y., Xia, F., Yang, H., Chen, Y., & Li, T. (2026). *OpenCEM: Multimodal photovoltaic and battery microgrid dataset with context records and sky imagery* (Version 1.0.0) [Dataset]. Zenodo. https://doi.org/10.5281/zenodo.21436223
