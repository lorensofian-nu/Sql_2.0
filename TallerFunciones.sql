CREATE DATABASE IF NOT EXISTS BancoDB;
USE BancoDB;

DROP TABLE IF EXISTS Transacciones;
DROP TABLE IF EXISTS Cuentas;

CREATE TABLE Cuentas (
    cuenta_id INT PRIMARY KEY,
    titular VARCHAR(100) NOT NULL,
    saldo DECIMAL(12,2) NOT NULL DEFAULT 0.00
);

CREATE TABLE Transacciones (
    transaccion_id INT AUTO_INCREMENT PRIMARY KEY,
    cuenta_id INT NOT NULL,
    tipo_transaccion VARCHAR(20) NOT NULL,
    monto DECIMAL(12,2) NOT NULL,
    fecha DATETIME DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_transacciones_cuentas FOREIGN KEY (cuenta_id) REFERENCES Cuentas(cuenta_id)
);

-- Índice optimizado para las funciones de consulta
CREATE INDEX idx_transacciones_busqueda 
ON Transacciones(cuenta_id, tipo_transaccion, fecha, monto);

INSERT INTO Cuentas (cuenta_id, titular, saldo) VALUES
(1, 'Ana López', 2500000.00),
(2, 'Carlos Pérez', 1000000.00),
(3, 'María Gómez', 200000.00);

INSERT INTO Transacciones (cuenta_id, tipo_transaccion, monto, fecha) VALUES
(1, 'Retiro', 500000.00, '2026-01-15 10:00:00'),
(1, 'Retiro', 300000.00, '2026-01-20 14:30:00'),
(1, 'Consignacion', 1000000.00, '2026-01-25 09:15:00'),
(2, 'Retiro', 200000.00, '2026-01-10 11:00:00');

-- EJERCICIO 1: Impuesto 4x1000 (Con validación de entrada)
DROP FUNCTION IF EXISTS CalcularImpuestoGMF;

DELIMITER //

CREATE FUNCTION CalcularImpuestoGMF(
    p_monto DECIMAL(12,2),
    p_es_exenta BOOLEAN
)
RETURNS DECIMAL(12,2)
DETERMINISTIC
BEGIN
    IF p_monto IS NULL OR p_monto <= 0 OR p_es_exenta THEN
        RETURN 0.00;
    END IF;
    
    RETURN p_monto * 0.004;
END //

DELIMITER ;

-- EJERCICIO 2: Total Retiros (Optimizado para uso de Índices)
DROP FUNCTION IF EXISTS ObtenerTotalRetirosPeriodo;

DELIMITER //

CREATE FUNCTION ObtenerTotalRetirosPeriodo(
    p_cuenta_id INT,
    p_fecha_inicio DATE,
    p_fecha_fin DATE
)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_total_retiros DECIMAL(12,2);
    
    SELECT IFNULL(SUM(monto), 0.00)
    INTO v_total_retiros
    FROM Transacciones
    WHERE cuenta_id = p_cuenta_id
      AND tipo_transaccion = 'Retiro'
      AND fecha >= p_fecha_inicio 
      AND fecha < DATE_ADD(p_fecha_fin, INTERVAL 1 DAY);
      
    RETURN v_total_retiros;
END //

DELIMITER ;

-- EJERCICIO 3: Rendimiento CDT (Con validación de fronteras)
DROP FUNCTION IF EXISTS ProyectarRendimientoCDT;

DELIMITER //

CREATE FUNCTION ProyectarRendimientoCDT(
    p_capital DECIMAL(12,2),
    p_tasa_anual DECIMAL(5,2),
    p_anios INT
)
RETURNS DECIMAL(12,2)
DETERMINISTIC
BEGIN
    DECLARE v_capital_acumulado DECIMAL(12,2);
    DECLARE v_contador INT DEFAULT 1;
    
    IF p_capital <= 0 OR p_anios <= 0 THEN
        RETURN IFNULL(p_capital, 0.00);
    END IF;
    
    SET v_capital_acumulado = p_capital;
    
    WHILE v_contador <= p_anios DO
        SET v_capital_acumulado = v_capital_acumulado * (1 + (p_tasa_anual / 100.0));
        SET v_contador = v_contador + 1;
    END WHILE;
    
    RETURN v_capital_acumulado;
END //

DELIMITER ;

-- EJERCICIO 4: Score Crediticio
DROP FUNCTION IF EXISTS EvaluarElegibilidadCredito;

DELIMITER //

CREATE FUNCTION EvaluarElegibilidadCredito(
    p_cuenta_id INT
)
RETURNS VARCHAR(30)
READS SQL DATA
BEGIN
    DECLARE v_saldo DECIMAL(12,2);
    DECLARE v_total_retiros DECIMAL(12,2);
    
    SELECT saldo INTO v_saldo
    FROM Cuentas
    WHERE cuenta_id = p_cuenta_id;
    
    IF v_saldo IS NULL THEN
        RETURN 'Cuenta Inexistente';
    END IF;
    
    SELECT IFNULL(SUM(monto), 0.00)
    INTO v_total_retiros
    FROM Transacciones
    WHERE cuenta_id = p_cuenta_id 
      AND tipo_transaccion = 'Retiro';
      
    IF v_saldo >= 2000000.00 AND v_total_retiros <= (v_saldo * 2) THEN
        RETURN 'Aprobado';
    ELSEIF v_saldo >= 500000.00 AND v_saldo < 2000000.00 THEN
        RETURN 'Requiere Aval';
    ELSE
        RETURN 'Rechazado';
    END IF;
END //

DELIMITER ;
-- ==========================================
-- CONSULTAS Y PRUEBAS DE RESULTADOS
-- ==========================================

-- Prueba Ejercicio 1 (GMF 4x1000)
SELECT CalcularImpuestoGMF(1000000.00, FALSE) AS Impuesto_4x1000;
SELECT CalcularImpuestoGMF(1000000.00, TRUE)  AS Impuesto_Exento;

-- Prueba Ejercicio 2 (Retiros en Rango)
SELECT ObtenerTotalRetirosPeriodo(1, '2026-01-01', '2026-01-31') AS Total_Retiros_Enero;

-- Prueba Ejercicio 3 (CDT)
SELECT ProyectarRendimientoCDT(10000000.00, 10.50, 3) AS Capital_Proyectado_3Anios;

-- Prueba Ejercicio 4 (Score Crediticio)
SELECT cuenta_id, titular, saldo, EvaluarElegibilidadCredito(cuenta_id) AS Estado_Credito 
FROM Cuentas;

-- Ver las tablas creadas
SELECT * FROM Cuentas;
SELECT * FROM Transacciones;

