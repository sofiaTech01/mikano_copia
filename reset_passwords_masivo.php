<?php
// reset_passwords_masivo.php
// Resetea passwords en tbcomercial usando la conexion del config.json.
// Uso:
//   php reset_passwords_masivo.php --password=12233
// Opcional:
//   --all              => actualiza todos los usuarios (sin filtro habilita)
//   --only-active      => actualiza solo habilita IN ('A','1') [default]
// Tambien puedes pasar la clave por variable de entorno:
//   set NUEVA_CLAVE=12233
//   php reset_passwords_masivo.php

$scriptDir = __DIR__;
$configFile = $scriptDir . DIRECTORY_SEPARATOR . 'config.json';
$logFile = $scriptDir . DIRECTORY_SEPARATOR . 'reset_passwords_masivo.log';

function write_log($message, $level = 'INFO')
{
    global $logFile;
    $line = '[' . date('Y-m-d H:i:s') . '] [' . $level . '] ' . $message . PHP_EOL;
    @file_put_contents($logFile, $line, FILE_APPEND);
}

function fail($message, $code = 1)
{
    write_log($message, 'ERROR');
    $line = "[ERROR] {$message}" . PHP_EOL;
    if (defined('STDERR') && is_resource(STDERR)) {
        fwrite(STDERR, $line);
    } else {
        $err = @fopen('php://stderr', 'w');
        if (is_resource($err)) {
            fwrite($err, $line);
            fclose($err);
        } else {
            echo $line;
        }
    }
    exit($code);
}

if (!file_exists($configFile)) {
    fail("No se encontro config.json en {$configFile}");
}

write_log("Inicio de ejecucion.");
write_log("Leyendo config desde: {$configFile}");

$configRaw = file_get_contents($configFile);
if ($configRaw === false) {
    fail("No se pudo leer config.json");
}

// Quita BOM UTF-8 si existe
if (substr($configRaw, 0, 3) === "\xEF\xBB\xBF") {
    $configRaw = substr($configRaw, 3);
    write_log("Se detecto y removio BOM UTF-8 en config.json.");
}

// Intenta normalizar si no viene en UTF-8 valido
if (!preg_match('//u', $configRaw)) {
    $converted = @iconv('Windows-1252', 'UTF-8//IGNORE', $configRaw);
    if ($converted !== false) {
        $configRaw = $converted;
        write_log("config.json fue convertido de Windows-1252 a UTF-8.");
    } else {
        write_log("No se pudo convertir config.json desde Windows-1252.", 'WARN');
    }
}

$config = json_decode($configRaw, true);
if (!is_array($config)) {
    if (function_exists('json_last_error_msg')) {
        fail("config.json no es JSON valido: " . json_last_error_msg());
    }
    fail("config.json no es JSON valido. Codigo: " . json_last_error());
}

$dbHost = isset($config['DbHost']) ? $config['DbHost'] : '';
$dbPort = isset($config['DbPort']) ? $config['DbPort'] : 3306;
$dbName = isset($config['DbName']) ? $config['DbName'] : '';
$dbUser = isset($config['DbUser']) ? $config['DbUser'] : '';
$dbPass = isset($config['DbPassword']) ? $config['DbPassword'] : '';

if ($dbHost === '' || $dbName === '' || $dbUser === '' || $dbPass === '') {
    fail("Faltan campos de BD en config.json (DbHost, DbName, DbUser, DbPassword)");
}

write_log("Config de BD leida. Host={$dbHost}, Port={$dbPort}, DB={$dbName}, User={$dbUser}");

$passwordArg = null;
$onlyActive = true;

foreach (array_slice($argv, 1) as $arg) {
    if (strpos($arg, '--password=') === 0) {
        $passwordArg = substr($arg, strlen('--password='));
        continue;
    }
    if ($arg === '--all') {
        $onlyActive = false;
        continue;
    }
    if ($arg === '--only-active') {
        $onlyActive = true;
        continue;
    }
}

$newPassword = $passwordArg !== null && $passwordArg !== '' ? $passwordArg : (getenv('NUEVA_CLAVE') ?: '');
if ($newPassword === '') {
    fail("Debes indicar la nueva clave con --password=TU_CLAVE o variable de entorno NUEVA_CLAVE");
}

write_log("Modo de actualizacion: " . ($onlyActive ? "solo activos" : "todos"));

try {
    write_log("Intentando conexion mysqli. Host={$dbHost}, Port={$dbPort}, DB={$dbName}, User={$dbUser}");
    $mysqli = @new mysqli($dbHost, $dbUser, $dbPass, $dbName, (int)$dbPort);
    if ($mysqli->connect_errno) {
        fail("Error de conexion mysqli: " . $mysqli->connect_error);
    }
    if (!$mysqli->set_charset("utf8mb4")) {
        fail("No se pudo establecer charset utf8mb4: " . $mysqli->error);
    }

    $hash = password_hash($newPassword, PASSWORD_BCRYPT);
    if ($hash === false) {
        fail("No se pudo generar hash bcrypt");
    }
    if (strlen($hash) < 60 || strpos($hash, '$2y$') !== 0) {
        fail("El hash generado no parece bcrypt valido. Hash: {$hash}");
    }

    $dbCheckResult = $mysqli->query("SELECT DATABASE() AS dbname");
    if (!$dbCheckResult) {
        fail("Error consultando base conectada: " . $mysqli->error);
    }
    $dbCheck = $dbCheckResult->fetch_assoc();
    $dbCheckResult->free();
    echo "[INFO] Base conectada: " . $dbCheck['dbname'] . PHP_EOL;
    write_log("Base conectada segun SQL: " . $dbCheck['dbname']);

    if ($onlyActive) {
        $sql = "UPDATE tbcomercial SET password = ? WHERE habilita IN ('A','1')";
    } else {
        $sql = "UPDATE tbcomercial SET password = ?";
    }

    $stmt = $mysqli->prepare($sql);
    if (!$stmt) {
        fail("Error preparando UPDATE: " . $mysqli->error);
    }
    if (!$stmt->bind_param("s", $hash)) {
        $stmt->close();
        fail("Error bind_param UPDATE: " . $stmt->error);
    }
    if (!$stmt->execute()) {
        $stmt->close();
        fail("Error ejecutando UPDATE: " . $stmt->error);
    }
    $updatedRows = $stmt->affected_rows;
    $stmt->close();
    write_log("UPDATE ejecutado. rowCount=" . $updatedRows);

    $verifySql = "SELECT COUNT(*) AS total, MIN(CHAR_LENGTH(password)) AS min_len, MAX(CHAR_LENGTH(password)) AS max_len
                  FROM tbcomercial
                  WHERE password = ?";
    $verifyStmt = $mysqli->prepare($verifySql);
    if (!$verifyStmt) {
        fail("Error preparando verificacion: " . $mysqli->error);
    }
    if (!$verifyStmt->bind_param("s", $hash)) {
        $verifyStmt->close();
        fail("Error bind_param verificacion: " . $verifyStmt->error);
    }
    if (!$verifyStmt->execute()) {
        $verifyStmt->close();
        fail("Error ejecutando verificacion: " . $verifyStmt->error);
    }
    if (!$verifyStmt->bind_result($verifyTotal, $verifyMinLen, $verifyMaxLen)) {
        $verifyStmt->close();
        fail("Error bind_result verificacion: " . $verifyStmt->error);
    }
    if (!$verifyStmt->fetch()) {
        $verifyStmt->close();
        fail("No se pudo leer resultado de verificacion.");
    }
    $verify = [
        'total' => $verifyTotal,
        'min_len' => $verifyMinLen,
        'max_len' => $verifyMaxLen
    ];
    $verifyStmt->close();

    echo "[OK] Usuarios actualizados: " . $updatedRows . PHP_EOL;
    echo "[OK] Modo: " . ($onlyActive ? "solo activos" : "todos") . PHP_EOL;
    echo "[INFO] Filas verificadas con hash exacto: " . (int)$verify['total'] . PHP_EOL;
    echo "[INFO] Largo min/max guardado: " . (int)$verify['min_len'] . "/" . (int)$verify['max_len'] . PHP_EOL;
    write_log("Verificacion: total=" . (int)$verify['total'] . ", min_len=" . (int)$verify['min_len'] . ", max_len=" . (int)$verify['max_len']);
    if ((int)$verify['total'] === 0 || (int)$verify['min_len'] < 50) {
        fail("La BD no guardo el bcrypt como se esperaba. Revisa si otra rutina o proceso reescribe la columna password.");
    }
    echo "[OK] Proceso finalizado." . PHP_EOL;
    write_log("Proceso finalizado correctamente.", 'SUCCESS');
    $mysqli->close();
} catch (Exception $e) {
    fail("Error durante la ejecucion: " . $e->getMessage());
}
