USE BancoDB;

-- ==============================================================================
-- PARTE 0: TABLAS DE AUDITORÍA Y MÉTRICAS (Estructura de Soporte Refactorizada)
-- ==============================================================================

-- Tabla de auditoría desvinculada de FK restrictiva para preservar histórico inmutable
CREATE TABLE IF NOT EXISTS auditoria_saldos (
    id_log BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_cuenta INT NOT NULL,
    saldo_anterior DECIMAL(15,2) NOT NULL,
    saldo_nuevo DECIMAL(15,2) NOT NULL,
    usuario VARCHAR(100) NOT NULL,
    fecha_modificacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_auditoria_cuenta (id_cuenta),
    INDEX idx_auditoria_fecha (fecha_modificacion)
) ENGINE=InnoDB;

-- Tabla de métricas con restricción UNIQUE por fecha para evitar duplicación
CREATE TABLE IF NOT EXISTS metricas_diarias (
    id_metrica INT AUTO_INCREMENT PRIMARY KEY,
    fecha_metrica DATE NOT NULL UNIQUE,
    total_cuentas INT NOT NULL,
    saldo_total_sistema DECIMAL(18,2) NOT NULL,
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- NUEVO: tabla para registrar errores de los EVENTS en vez de fallar en silencio
CREATE TABLE IF NOT EXISTS log_errores_eventos (
    id_log INT AUTO_INCREMENT PRIMARY KEY,
    evento VARCHAR(100) NOT NULL,
    error_num INT,
    mensaje VARCHAR(500),
    fecha_error TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- IMPORTANTE: event_scheduler=ON no persiste tras reiniciar MySQL.
-- Para producción, agregar en my.cnf / my.ini:
--     [mysqld]
--     event_scheduler=ON
-- El SET GLOBAL siguiente es solo para activar en la sesión actual del despliegue.
SET GLOBAL event_scheduler = ON;


-- ==============================================================================
-- PARTE 1: DEMOSTRACIÓN GUIADA (REFACTORIZADA)
-- ==============================================================================

-- 1.1 TRIGGER: Auditoría de Saldo con comparación Null-Safe
DELIMITER //

DROP TRIGGER IF EXISTS trg_auditar_cambio_saldo //

CREATE TRIGGER trg_auditar_cambio_saldo
AFTER UPDATE ON cuentas
FOR EACH ROW
BEGIN
    -- Comparación robusta segura ante valores nulos
    IF NOT (OLD.saldo <=> NEW.saldo) THEN
        INSERT INTO auditoria_saldos (
            id_cuenta,
            saldo_anterior,
            saldo_nuevo,
            usuario
        )
        VALUES (
            NEW.id_cuenta,
            OLD.saldo,
            NEW.saldo,
            -- Usa el usuario de aplicación si la sesión lo define (SET @app_user = 'loren123'),
            -- y cae de vuelta a USER() (usuario@host de MySQL) si no existe.
            IFNULL(@app_user, USER())
        );
    END IF;
END //

DELIMITER ;

-- 1.2 EVENTO: Resumen de Métricas (Programado a las 01:00 AM con Upsert)
DELIMITER //

DROP EVENT IF EXISTS evt_registrar_metricas_diarias //

CREATE EVENT evt_registrar_metricas_diarias
ON SCHEDULE EVERY 1 DAY
-- Fecha de arranque fija: un DROP/CREATE posterior no "pierde" la ejecución
-- de hoy solo porque el script se corrió después de la 1:00 AM.
STARTS '2026-01-01 01:00:00'
ON COMPLETION PRESERVE
COMMENT 'Consolida saldos y cuentas activas a la 1:00 AM de forma idempotente'
DO
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @errno = MYSQL_ERRNO, @msg = MESSAGE_TEXT;
        INSERT INTO log_errores_eventos (evento, error_num, mensaje)
        VALUES ('evt_registrar_metricas_diarias', @errno, @msg);
    END;

    INSERT INTO metricas_diarias (fecha_metrica, total_cuentas, saldo_total_sistema)
    SELECT
        CURDATE(),
        COUNT(id_cuenta),
        IFNULL(SUM(saldo), 0.00)
    FROM cuentas
    WHERE estado = 'Activa'
    ON DUPLICATE KEY UPDATE
        total_cuentas = VALUES(total_cuentas),
        saldo_total_sistema = VALUES(saldo_total_sistema);
END //

DELIMITER ;


-- ==============================================================================
-- PARTE 2: RETO AUTÓNOMO REFACTORIZADO (NIVEL PRODUCCIÓN)
-- ==============================================================================

-- 2.1 TRIGGER: Validación Integral de Transferencias
-- NOTA: este trigger SOLO valida. El bloqueo real de fila (FOR UPDATE) se hace
-- en el procedimiento sp_realizar_transferencia de abajo, que es el único punto
-- de entrada recomendado para ejecutar transferencias. Si insertas directamente
-- en historial_transferencias sin pasar por ese procedimiento, seguirás expuesto
-- a condiciones de carrera porque un trigger no puede bloquear la fila que
-- todavía no ha sido actualizada.
DELIMITER //

DROP TRIGGER IF EXISTS trg_validar_transferencia //

CREATE TRIGGER trg_validar_transferencia
BEFORE INSERT ON historial_transferencias
FOR EACH ROW
BEGIN
    DECLARE v_saldo_origen DECIMAL(15,2);
    DECLARE v_estado_origen VARCHAR(20);
    DECLARE v_estado_destino VARCHAR(20);

    -- Regla 1: Monto estrictamente positivo
    IF NEW.monto <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: El monto de la transferencia debe ser mayor a cero.';
    END IF;

    -- Regla 2: Origen y destino distintos
    IF NEW.cuenta_origen = NEW.cuenta_destino THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de origen y destino no pueden ser iguales.';
    END IF;

    -- Regla 3: Obtener estado y saldo de la cuenta origen
    SELECT saldo, estado INTO v_saldo_origen, v_estado_origen
    FROM cuentas
    WHERE id_cuenta = NEW.cuenta_origen;

    IF v_estado_origen IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de origen no existe.';
    ELSEIF v_estado_origen <> 'Activa' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de origen no se encuentra activa.';
    ELSEIF v_saldo_origen < NEW.monto THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: Fondos insuficientes para realizar la transferencia.';
    END IF;

    -- Regla 4: Validar estado de la cuenta destino
    SELECT estado INTO v_estado_destino
    FROM cuentas
    WHERE id_cuenta = NEW.cuenta_destino;

    IF v_estado_destino IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de destino no existe.';
    ELSEIF v_estado_destino <> 'Activa' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de destino no se encuentra activa.';
    END IF;
END //

DELIMITER ;

-- 2.1.b PROCEDIMIENTO: Transferencia atómica y segura contra condiciones de carrera
-- Encapsula débito + crédito + registro de historial en una sola transacción,
-- bloqueando ambas filas con FOR UPDATE en orden consistente (menor id primero)
-- para evitar deadlocks entre transferencias cruzadas concurrentes.
DELIMITER //

DROP PROCEDURE IF EXISTS sp_realizar_transferencia //

CREATE PROCEDURE sp_realizar_transferencia (
    IN p_cuenta_origen INT,
    IN p_cuenta_destino INT,
    IN p_monto DECIMAL(15,2),
    IN p_usuario VARCHAR(100)
)
proc_body: BEGIN
    DECLARE v_saldo_origen DECIMAL(15,2);
    DECLARE v_estado_origen VARCHAR(20);
    DECLARE v_estado_destino VARCHAR(20);
    DECLARE v_primero INT;
    DECLARE v_segundo INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Variable de sesión que el trigger de auditoría usará como usuario real
    SET @app_user = p_usuario;

    IF p_monto <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: El monto debe ser mayor a cero.';
    END IF;

    IF p_cuenta_origen = p_cuenta_destino THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: Origen y destino no pueden ser iguales.';
    END IF;

    START TRANSACTION;

    -- Bloquear ambas cuentas en orden consistente (id ascendente) para prevenir deadlocks
    SET v_primero = LEAST(p_cuenta_origen, p_cuenta_destino);
    SET v_segundo = GREATEST(p_cuenta_origen, p_cuenta_destino);

    SELECT saldo, estado INTO v_saldo_origen, v_estado_origen
    FROM cuentas WHERE id_cuenta = v_primero FOR UPDATE;

    SELECT estado INTO v_estado_destino
    FROM cuentas WHERE id_cuenta = v_segundo FOR UPDATE;

    -- Reasignar variables según cuál de las dos filas bloqueadas es realmente el origen
    IF v_primero <> p_cuenta_origen THEN
        SELECT saldo, estado INTO v_saldo_origen, v_estado_origen
        FROM cuentas WHERE id_cuenta = p_cuenta_origen;
        SELECT estado INTO v_estado_destino
        FROM cuentas WHERE id_cuenta = p_cuenta_destino;
    END IF;

    IF v_estado_origen IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de origen no existe.';
    ELSEIF v_estado_origen <> 'Activa' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de origen no se encuentra activa.';
    ELSEIF v_saldo_origen < p_monto THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: Fondos insuficientes para realizar la transferencia.';
    END IF;

    IF v_estado_destino IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de destino no existe.';
    ELSEIF v_estado_destino <> 'Activa' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Error de Negocio: La cuenta de destino no se encuentra activa.';
    END IF;

    UPDATE cuentas SET saldo = saldo - p_monto WHERE id_cuenta = p_cuenta_origen;
    UPDATE cuentas SET saldo = saldo + p_monto WHERE id_cuenta = p_cuenta_destino;

    INSERT INTO historial_transferencias (cuenta_origen, cuenta_destino, monto)
    VALUES (p_cuenta_origen, p_cuenta_destino, p_monto);

    COMMIT;

    SET @app_user = NULL;
END proc_body //

DELIMITER ;


-- 2.2 EVENTO: Inactivación Nocturna de Cuentas en Cero/Negativo
DELIMITER //

DROP EVENT IF EXISTS evt_inactivar_cuentas_vacias //

CREATE EVENT evt_inactivar_cuentas_vacias
ON SCHEDULE EVERY 1 DAY
STARTS '2026-01-01 02:00:00'
ON COMPLETION PRESERVE
COMMENT 'Inactiva cuentas activas con saldo cero o negativo durante la ventana nocturna'
DO
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @errno = MYSQL_ERRNO, @msg = MESSAGE_TEXT;
        INSERT INTO log_errores_eventos (evento, error_num, mensaje)
        VALUES ('evt_inactivar_cuentas_vacias', @errno, @msg);
    END;

    UPDATE cuentas
    SET estado = 'Inactiva'
    WHERE saldo <= 0.00
      AND estado = 'Activa';
END //

DELIMITER ;

-- Reemplaza la Parte 3 completa por esto:

DELIMITER //

DROP PROCEDURE IF EXISTS sp_crear_indice_si_no_existe //

CREATE PROCEDURE sp_crear_indice_si_no_existe(
    IN p_tabla VARCHAR(64),
    IN p_indice VARCHAR(64),
    IN p_columna VARCHAR(64)
)
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics
        WHERE table_schema = DATABASE()
          AND table_name = p_tabla
          AND index_name = p_indice
    ) THEN
        SET @sql = CONCAT('CREATE INDEX ', p_indice, ' ON ', p_tabla, ' (', p_columna, ')');
        PREPARE stmt FROM @sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;
END //

DELIMITER ;

CALL sp_crear_indice_si_no_existe('cuentas', 'idx_cuentas_estado', 'estado');
CALL sp_crear_indice_si_no_existe('historial_transferencias', 'idx_transferencias_origen', 'cuenta_origen');
CALL sp_crear_indice_si_no_existe('historial_transferencias', 'idx_transferencias_destino', 'cuenta_destino');

DROP PROCEDURE IF EXISTS sp_crear_indice_si_no_existe;
SHOW INDEX FROM cuentas WHERE Key_name = 'idx_cuentas_estado';
SHOW INDEX FROM historial_transferencias WHERE Key_name IN ('idx_transferencias_origen', 'idx_transferencias_destino');