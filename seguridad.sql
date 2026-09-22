-- ============================================================================
-- TALLER PRÁCTICO: SEGURIDAD, PERMISOS Y PREVENCIÓN DE SQL INJECTION EN MYSQL
-- Dominio: Sistema Bancario (BancoBD)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PASO 0: Preparación del Entorno (Ejecutado como ROOT o Administrador)
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS BancoBD;
USE BancoBD;

-- Estructura de tablas base
CREATE TABLE IF NOT EXISTS cuentas (
    id_cuenta INT PRIMARY KEY AUTO_INCREMENT,
    titular VARCHAR(100) NOT NULL,
    saldo DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    estado VARCHAR(20) DEFAULT 'Activa'
);

CREATE TABLE IF NOT EXISTS historial_transferencias (
    id_transferencia INT AUTO_INCREMENT PRIMARY KEY,
    cuenta_origen INT NOT NULL,
    cuenta_destino INT NOT NULL,
    monto DECIMAL(10, 2) NOT NULL,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (cuenta_origen) REFERENCES cuentas(id_cuenta),
    FOREIGN KEY (cuenta_destino) REFERENCES cuentas(id_cuenta)
);

-- Insertar datos iniciales de prueba
INSERT INTO cuentas (titular, saldo, estado) VALUES
('Carlos Mendoza', 2500000.00, 'Activa'),
('Ana Gómez', 850000.00, 'Activa'),
('Roberto Silva', 120000.00, 'Bloqueada');

-- ----------------------------------------------------------------------------
-- PASO 1: Higiene de Seguridad - Limpieza de Usuarios Anónimos
-- ----------------------------------------------------------------------------
-- Eliminar usuarios anónimos que representan un riesgo de seguridad
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';

-- ----------------------------------------------------------------------------
-- PASO 2: Creación de Usuarios por Roles ('usuario'@'host')
-- ----------------------------------------------------------------------------
-- Limpiar usuarios si existían previamente
DROP USER IF EXISTS 'admin_banco'@'localhost';
DROP USER IF EXISTS 'cajero_app'@'localhost';
DROP USER IF EXISTS 'auditor_consulta'@'%';
DROP USER IF EXISTS 'app_backend'@'localhost';

-- 1. Usuario Administrador local
CREATE USER 'admin_banco'@'localhost' IDENTIFIED BY 'AdminBank2026!#';

-- 2. Usuario Cajero (Acceso restringido)
CREATE USER 'cajero_app'@'localhost' IDENTIFIED BY 'CajeroPass2026!';

-- 3. Usuario Auditor (Acceso remoto de consulta)
CREATE USER 'auditor_consulta'@'%' IDENTIFIED BY 'AuditorPass2026!';

-- 4. Usuario Aplicación Backend
CREATE USER 'app_backend'@'localhost' IDENTIFIED BY 'AppBackend2026!Sec';

-- ----------------------------------------------------------------------------
-- PASO 3: Asignación Granular de Privilegios (GRANT)
-- ----------------------------------------------------------------------------
-- A) Administrador: Privilegios totales sobre la base de datos del banco
GRANT ALL PRIVILEGES ON BancoBD.* TO 'admin_banco'@'localhost' WITH GRANT OPTION;

-- B) Aplicación Backend: Operaciones DML (Lectura, Inserción y Actualización)
GRANT SELECT, INSERT, UPDATE ON BancoBD.* TO 'app_backend'@'localhost';

-- C) Cajero: Restricción a columnas específicas de la tabla cuentas
-- Solo puede ver id_cuenta, titular y saldo
GRANT SELECT (id_cuenta, titular, saldo), UPDATE (saldo) ON BancoBD.cuentas TO 'cajero_app'@'localhost';

-- D) Auditor: Privilegio de solo lectura sobre todo el esquema
GRANT SELECT ON BancoBD.* TO 'auditor_consulta'@'%';

-- Aplicar cambios en la tabla de privilegios
FLUSH PRIVILEGES;

-- ----------------------------------------------------------------------------
-- PASO 4: Verificación y Revocación de Privilegios (REVOKE & SHOW GRANTS)
-- ----------------------------------------------------------------------------
-- Consultar privilegios otorgados
SHOW GRANTS FOR 'cajero_app'@'localhost';
SHOW GRANTS FOR 'app_backend'@'localhost';

-- Revocar permiso de actualización al cajero
REVOKE UPDATE ON BancoBD.cuentas FROM 'cajero_app'@'localhost';
FLUSH PRIVILEGES;

-- ----------------------------------------------------------------------------
-- PASO 5: Prevención de SQL Injection con Sentencias Preparadas (PREPARE)
-- ----------------------------------------------------------------------------
-- Declaración de la sentencia preparada con marcadores de posición '?'
PREPARE stmt_buscar_cuenta FROM 
'SELECT id_cuenta, titular, saldo, estado FROM cuentas WHERE id_cuenta = ? AND estado = ?';

-- Definición de variables de sesión
SET @id_busqueda = 1;
SET @estado_busqueda = 'Activa';

-- Ejecución segura de la consulta
EXECUTE stmt_buscar_cuenta USING @id_busqueda, @estado_busqueda;

-- Liberar la sentencia de memoria
DEALLOCATE PREPARE stmt_buscar_cuenta;