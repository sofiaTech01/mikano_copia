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

function fail($message, $code = 1)
{
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

$configRaw = file_get_contents($configFile);
if ($configRaw === false) {
    fail("No se pudo leer config.json");
}

// Quita BOM UTF-8 si existe
if (substr($configRaw, 0, 3) === "\xEF\xBB\xBF") {
    $configRaw = substr($configRaw, 3);
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

try {
    $dsn = "mysql:host={$dbHost};port={$dbPort};dbname={$dbName};charset=utf8mb4";
    $pdo = new PDO($dsn, $dbUser, $dbPass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);

    $hash = password_hash($newPassword, PASSWORD_BCRYPT);
    if ($hash === false) {
        fail("No se pudo generar hash bcrypt");
    }
    if (strlen($hash) < 60 || strpos($hash, '$2y$') !== 0) {
        fail("El hash generado no parece bcrypt valido. Hash: {$hash}");
    }

    $dbCheck = $pdo->query("SELECT DATABASE() AS dbname")->fetch();
    echo "[INFO] Base conectada: " . $dbCheck['dbname'] . PHP_EOL;

    if ($onlyActive) {
        $sql = "UPDATE tbcomercial SET password = :hash WHERE habilita IN ('A','1')";
    } else {
        $sql = "UPDATE tbcomercial SET password = :hash";
    }

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':hash' => $hash]);

    $verifySql = "SELECT COUNT(*) AS total, MIN(CHAR_LENGTH(password)) AS min_len, MAX(CHAR_LENGTH(password)) AS max_len
                  FROM tbcomercial
                  WHERE password = :hash";
    $verifyStmt = $pdo->prepare($verifySql);
    $verifyStmt->execute([':hash' => $hash]);
    $verify = $verifyStmt->fetch();

    echo "[OK] Usuarios actualizados: " . $stmt->rowCount() . PHP_EOL;
    echo "[OK] Modo: " . ($onlyActive ? "solo activos" : "todos") . PHP_EOL;
    echo "[INFO] Filas verificadas con hash exacto: " . (int)$verify['total'] . PHP_EOL;
    echo "[INFO] Largo min/max guardado: " . (int)$verify['min_len'] . "/" . (int)$verify['max_len'] . PHP_EOL;
    if ((int)$verify['total'] === 0 || (int)$verify['min_len'] < 50) {
        fail("La BD no guardo el bcrypt como se esperaba. Revisa si otra rutina o proceso reescribe la columna password.");
    }
    echo "[OK] Proceso finalizado." . PHP_EOL;
} catch (Exception $e) {
    fail("Error durante la ejecucion: " . $e->getMessage());
}
