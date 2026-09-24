CREATE DATABASE IF NOT EXISTS BancoDB;
USE BancoDB;

DROP TABLE IF EXISTS historial_transferencias;
DROP TABLE IF EXISTS cuentas;

CREATE TABLE cuentas (
    id_cuenta INT PRIMARY KEY,
    titular VARCHAR(100) NOT NULL,
    saldo DECIMAL(10,2) NOT NULL DEFAULT 0.00
);

CREATE TABLE historial_transferencias (
    id_transferencia INT AUTO_INCREMENT PRIMARY KEY,
    cuenta_origen INT NOT NULL,
    cuenta_destino INT NOT NULL,
    monto DECIMAL(10,2) NOT NULL,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    usuario_responsable VARCHAR(100) NOT NULL,
    CONSTRAINT fk_cuenta_origen FOREIGN KEY (cuenta_origen) REFERENCES cuentas(id_cuenta),
    CONSTRAINT fk_cuenta_destino FOREIGN KEY (cuenta_destino) REFERENCES cuentas(id_cuenta)
);

INSERT INTO cuentas (id_cuenta, titular, saldo) VALUES
(1, 'Ana López', 5000.00),
(2, 'Carlos Pérez', 3000.00);

DROP PROCEDURE IF EXISTS TransferirFondos;

DELIMITER //

CREATE PROCEDURE TransferirFondos(
    IN p_origen INT,
    IN p_destino INT,
    IN p_monto DECIMAL(10,2),
    IN p_usuario VARCHAR(100),
    OUT p_codigo_respuesta INT,
    OUT p_titular_origen VARCHAR(100)
)
BEGIN
    DECLARE v_saldo_actual DECIMAL(10,2);
    DECLARE v_id_menor INT;
    DECLARE v_id_mayor INT;
    DECLARE v_existe_destino INT DEFAULT 0;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_codigo_respuesta = 500;
        SET p_titular_origen = NULL;
    END;

    IF p_monto <= 0 THEN
        SET p_codigo_respuesta = 401;
        SET p_titular_origen = NULL;
    ELSEIF p_origen = p_destino THEN
        SET p_codigo_respuesta = 402;
        SET p_titular_origen = NULL;
    ELSE
        IF p_origen < p_destino THEN
            SET v_id_menor = p_origen;
            SET v_id_mayor = p_destino;
        ELSE
            SET v_id_menor = p_destino;
            SET v_id_mayor = p_origen;
        END IF;

        START TRANSACTION;

        PERFORM_LOCK: BEGIN
            DECLARE dummy INT;
            SELECT id_cuenta INTO dummy FROM cuentas WHERE id_cuenta = v_id_menor FOR UPDATE;
            SELECT id_cuenta INTO dummy FROM cuentas WHERE id_cuenta = v_id_mayor FOR UPDATE;
        END PERFORM_LOCK;

        SELECT saldo, titular INTO v_saldo_actual, p_titular_origen
        FROM cuentas 
        WHERE id_cuenta = p_origen;

        SELECT COUNT(*) INTO v_existe_destino
        FROM cuentas
        WHERE id_cuenta = p_destino;

        IF p_titular_origen IS NULL OR v_existe_destino = 0 THEN
            ROLLBACK;
            SET p_codigo_respuesta = 404;
            SET p_titular_origen = NULL;
        ELSEIF v_saldo_actual < p_monto THEN
            ROLLBACK;
            SET p_codigo_respuesta = 400;
        ELSE
            UPDATE cuentas SET saldo = saldo - p_monto WHERE id_cuenta = p_origen;
            UPDATE cuentas SET saldo = saldo + p_monto WHERE id_cuenta = p_destino;

            INSERT INTO historial_transferencias (cuenta_origen, cuenta_destino, monto, usuario_responsable)
            VALUES (p_origen, p_destino, p_monto, p_usuario);

            COMMIT;
            SET p_codigo_respuesta = 200;
        END IF;
    END IF;
END //

DELIMITER ;

-- Pruebas
CALL TransferirFondos(1, 2, 1000.00, 'cajero_01', @codigo, @titular);
SELECT 'Prueba 1' AS caso, @codigo AS codigo_respuesta, @titular AS titular_origen;

CALL TransferirFondos(1, 2, 10000.00, 'cajero_01', @codigo, @titular);
SELECT 'Prueba 2' AS caso, @codigo AS codigo_respuesta, @titular AS titular_origen;

CALL TransferirFondos(1, 2, -500.00, 'cajero_01', @codigo, @titular);
SELECT 'Prueba 3' AS caso, @codigo AS codigo_respuesta;

CALL TransferirFondos(1, 1, 500.00, 'cajero_01', @codigo, @titular);
SELECT 'Prueba 4' AS caso, @codigo AS codigo_respuesta;

CALL TransferirFondos(99, 2, 500.00, 'cajero_01', @codigo, @titular);
SELECT 'Prueba 5' AS caso, @codigo AS codigo_respuesta;

-- Verificación de tablas
SELECT * FROM cuentas;
SELECT * FROM historial_transferencias;