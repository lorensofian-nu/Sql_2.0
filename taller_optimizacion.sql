-- ==============================================================================
-- TALLER PRÁCTICO: OPTIMIZACIÓN DE CONSULTAS Y RENDIMIENTO EN MYSQL (BancoDB)
-- ==============================================================================
-- Objetivo: Que los estudiantes diagnostiquen consultas lentas usando EXPLAIN ANALYZE,
-- identifiquen lecturas completas de tabla (Table Scans), reescriban consultas
-- de forma sargable y apliquen índices compuestos y cubrientes sobre la base de datos bancaria.
-- ==============================================================================

CREATE DATABASE IF NOT EXISTS BancoDB;
USE BancoDB;

-- ------------------------------------------------------------------------------
-- PARTE 0: ESTRUCTURA DE TABLAS Y POBLAMIENTO DE DATOS MASIVOS
-- ------------------------------------------------------------------------------

-- Garantizar un entorno limpio al reejecutar
DROP TABLE IF EXISTS historial_transferencias;
DROP TABLE IF EXISTS cuentas;

CREATE TABLE cuentas (
    id_cuenta INT PRIMARY KEY AUTO_INCREMENT,
    titular VARCHAR(100) NOT NULL,
    tipo_cuenta VARCHAR(20) NOT NULL DEFAULT 'Ahorros',
    saldo DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    estado VARCHAR(20) NOT NULL DEFAULT 'Activa',
    fecha_apertura DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE historial_transferencias (
    id_transferencia INT AUTO_INCREMENT PRIMARY KEY,
    cuenta_origen INT NOT NULL,
    cuenta_destino INT NOT NULL,
    monto DECIMAL(12, 2) NOT NULL,
    estado_transferencia VARCHAR(20) NOT NULL DEFAULT 'Exitosa',
    fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (cuenta_origen) REFERENCES cuentas(id_cuenta),
    FOREIGN KEY (cuenta_destino) REFERENCES cuentas(id_cuenta)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Procedimiento optimizado con transacciones explícitas (inserción ultrarrápida)
DROP PROCEDURE IF EXISTS CargarDatosPrueba;
DELIMITER //
CREATE PROCEDURE CargarDatosPrueba()
BEGIN
    DECLARE i INT DEFAULT 1;
    
    START TRANSACTION; -- Optimización de I/O en InnoDB
    
    -- Insertar 1,000 cuentas
    WHILE i <= 1000 DO
        INSERT INTO cuentas (titular, tipo_cuenta, saldo, estado, fecha_apertura)
        VALUES (
            CONCAT('Cliente_', i),
            IF(i % 2 = 0, 'Ahorros', 'Corriente'),
            ROUND(RAND() * 10000000, 2),
            IF(i % 10 = 0, 'Bloqueada', 'Activa'),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY)
        );
        SET i = i + 1;
    END WHILE;

    -- Insertar 10,000 transferencias
    SET i = 1;
    WHILE i <= 10000 DO
        INSERT INTO historial_transferencias (cuenta_origen, cuenta_destino, monto, estado_transferencia, fecha)
        VALUES (
            FLOOR(1 + RAND() * 999),
            FLOOR(1 + RAND() * 999),
            ROUND(1000 + RAND() * 500000, 2),
            IF(i % 15 = 0, 'Fallida', 'Exitosa'),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 180) DAY)
        );
        SET i = i + 1;
    END WHILE;

    COMMIT; -- Confirmación de bloque masivo
END //
DELIMITER ;

-- Ejecutar la carga masiva
CALL CargarDatosPrueba();
DROP PROCEDURE IF EXISTS CargarDatosPrueba;


-- ==============================================================================
-- PARTE 1: DEMOSTRACIÓN GUIADA EN CLASE (PROFESOR)
-- ==============================================================================

-- PROBLEMA: Búsqueda de transferencias por estado y rango de fechas dinámico sin índice secundario.
EXPLAIN ANALYZE
SELECT id_transferencia, cuenta_origen, monto, fecha
FROM historial_transferencias
WHERE estado_transferencia = 'Exitosa'
  AND fecha >= DATE_SUB(NOW(), INTERVAL 30 DAY);

-- DIAGNÓSTICO:
-- Observar en la salida 'Table scan on historial_transferencias' y el costo alto.

-- SOLUCIÓN DEMOSTRATIVA: Crear índice compuesto ordenado por discriminación.
DROP INDEX IF EXISTS idx_transf_estado_fecha ON historial_transferencias;
CREATE INDEX idx_transf_estado_fecha ON historial_transferencias(estado_transferencia, fecha);

-- RE-EVALUACIÓN:
EXPLAIN ANALYZE
SELECT id_transferencia, cuenta_origen, monto, fecha
FROM historial_transferencias
WHERE estado_transferencia = 'Exitosa'
  AND fecha >= DATE_SUB(NOW(), INTERVAL 30 DAY);


-- ==============================================================================
-- PARTE 2: EJERCICIOS PRÁCTICOS PARA LOS ESTUDIANTES (A IMPLEMENTAR)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- EJERCICIO 1: Diagnóstico de "Non-Sargable Query" (Uso de Funciones en WHERE)
-- ------------------------------------------------------------------------------
-- ENUNCIADO: El sistema ejecuta la siguiente consulta para obtener las transferencias
-- realizadas hace 10 días exactos. El desarrollador anterior aplicó la función DATE() 
-- sobre la columna 'fecha'.

-- BASE INEFICIENTE (A ejecutar y analizar):
EXPLAIN ANALYZE
SELECT * 
FROM historial_transferencias 
WHERE DATE(fecha) = DATE_SUB(CURRENT_DATE, INTERVAL 10 DAY);

-- [SOLUCIÓN DEL ESTUDIANTE]
-- 1. Explicación: Aplicar funciones sobre columnas en el WHERE rompe la sargabilidad porque 
--    MySQL debe evaluar la función fila por fila en toda la tabla. Además, 'idx_transf_estado_fecha'
--    no inicia con 'fecha' (Leftmost Prefix Rule), impidiendo un B-Tree Range Scan directo.

-- 2. Índice adecuado para búsquedas por fecha + Consulta Sargable:
DROP INDEX IF EXISTS idx_transf_fecha ON historial_transferencias;
CREATE INDEX idx_transf_fecha ON historial_transferencias(fecha);

EXPLAIN ANALYZE
SELECT * 
FROM historial_transferencias 
WHERE fecha >= DATE_SUB(CURRENT_DATE, INTERVAL 10 DAY)
  AND fecha < DATE_SUB(CURRENT_DATE, INTERVAL 9 DAY);


-- ------------------------------------------------------------------------------
-- EJERCICIO 2: Optimización mediante Índices Cubrientes (Covering Index)
-- ------------------------------------------------------------------------------
-- ENUNCIADO: La aplicación consulta frecuentemente el saldo y tipo de cuenta de clientes activos
-- para validar autorizaciones rápidas.

-- BASE INEFICIENTE:
EXPLAIN ANALYZE
SELECT titular, saldo, tipo_cuenta
FROM cuentas
WHERE estado = 'Activa';

-- [SOLUCIÓN DEL ESTUDIANTE]
-- 1. Explicación: Usar SELECT * u omitir campos en el índice fuerza búsquedas en disco 
--    (Key Lookup / Primary Key Lookup en InnoDB).

-- 2. Diseño del Índice Cubriente:
DROP INDEX IF EXISTS idx_cuentas_estado_cubriente ON cuentas;
CREATE INDEX idx_cuentas_estado_cubriente 
ON cuentas(estado, titular, saldo, tipo_cuenta);

-- 3. Ejecución de EXPLAIN ANALYZE (Verificar "Using index" en el plan):
EXPLAIN ANALYZE
SELECT titular, saldo, tipo_cuenta
FROM cuentas
WHERE estado = 'Activa';


-- ------------------------------------------------------------------------------
-- EJERCICIO 3: Optimización de Filtros Combinados y JOINs
-- ------------------------------------------------------------------------------
-- ENUNCIADO: Se requiere generar un reporte de los clientes con cuentas activas que hayan realizado
-- transferencias superiores a $300,000 en los últimos 30 días.

-- BASE INEFICIENTE:
EXPLAIN ANALYZE
SELECT c.id_cuenta, c.titular, ht.id_transferencia, ht.monto, ht.fecha
FROM cuentas c
JOIN historial_transferencias ht ON c.id_cuenta = ht.cuenta_origen
WHERE c.estado = 'Activa'
  AND ht.monto > 300000.00
  AND ht.fecha >= DATE_SUB(CURRENT_DATE, INTERVAL 30 DAY);

-- [SOLUCIÓN DEL ESTUDIANTE]
-- 1. Identificación: La tabla 'historial_transferencias' genera un Full Table Scan durante el JOIN.

-- 2. Creación del Índice Optimizado:
DROP INDEX IF EXISTS idx_transf_cuenta_fecha_monto ON historial_transferencias;
CREATE INDEX idx_transf_cuenta_fecha_monto 
ON historial_transferencias(cuenta_origen, fecha, monto);

-- 3. Verificación con EXPLAIN ANALYZE:
EXPLAIN ANALYZE
SELECT c.id_cuenta, c.titular, ht.id_transferencia, ht.monto, ht.fecha
FROM cuentas c
JOIN historial_transferencias ht ON c.id_cuenta = ht.cuenta_origen
WHERE c.estado = 'Activa'
  AND ht.monto > 300000.00
  AND ht.fecha >= DATE_SUB(CURRENT_DATE, INTERVAL 30 DAY);

-- Justificación del orden:
-- 'cuenta_origen' va PRIMERO por la regla de "Igualdad antes que Rango" (se evalúa en el JOIN como igualdad exacta).
-- 'fecha' y 'monto' van DESPUÉS por ser condiciones de rango (>= y >).

-- ==============================================================================
-- FIN DEL TALLER 
-- ==============================================================================