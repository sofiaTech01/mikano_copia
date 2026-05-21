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

declare(strict_types=1);

$scriptDir = __DIR__;
$configFile = $scriptDir . DIRECTORY_SEPARATOR . 'config.json';

function fail(string $message, int $code = 1): void
{
    fwrite(STDERR, "[ERROR] {$message}" . PHP_EOL);
    exit($code);
}

if (!file_exists($configFile)) {
    fail("No se encontro config.json en {$configFile}");
}

$configRaw = file_get_contents($configFile);
if ($configRaw === false) {
    fail("No se pudo leer config.json");
}

$config = json_decode($configRaw, true);
if (!is_array($config)) {
    fail("config.json no es JSON valido");
}

$dbHost = $config['DbHost'] ?? '';
$dbPort = $config['DbPort'] ?? 3306;
$dbName = $config['DbName'] ?? '';
$dbUser = $config['DbUser'] ?? '';
$dbPass = $config['DbPassword'] ?? '';

if ($dbHost === '' || $dbName === '' || $dbUser === '' || $dbPass === '') {
    fail("Faltan campos de BD en config.json (DbHost, DbName, DbUser, DbPassword)");
}

$passwordArg = null;
$onlyActive = true;

foreach (array_slice($argv, 1) as $arg) {
    if (str_starts_with($arg, '--password=')) {
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

    if ($onlyActive) {
        $sql = "UPDATE tbcomercial SET password = :hash WHERE habilita IN ('A','1')";
    } else {
        $sql = "UPDATE tbcomercial SET password = :hash";
    }

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':hash' => $hash]);

    echo "[OK] Usuarios actualizados: " . $stmt->rowCount() . PHP_EOL;
    echo "[OK] Modo: " . ($onlyActive ? "solo activos" : "todos") . PHP_EOL;
    echo "[OK] Proceso finalizado." . PHP_EOL;
} catch (Throwable $e) {
    fail("Error durante la ejecucion: " . $e->getMessage());
}

