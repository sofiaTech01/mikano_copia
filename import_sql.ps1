# ==============================================================================
# Script de Importacion de Backup SQL
# ==============================================================================
# Este script busca el archivo .sql mas reciente en ExtractDir y lo importa
# en MySQL/MariaDB.
# ==============================================================================

$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogFile = Join-Path $ScriptDir "import.log"

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"
    Write-Output $LogLine
    Add-Content -Path $LogFile -Value $LogLine
}

Write-Log "Iniciando proceso de importacion SQL..."

if (!(Test-Path -Path $ConfigFile)) {
    Write-Log "Error: No se encontro el archivo de configuracion en '$ConfigFile'." "ERROR"
    exit 1
}

try {
    $ConfigContent = Get-Content -Raw -Path $ConfigFile -ErrorAction Stop
    $Config = ConvertFrom-Json $ConfigContent -ErrorAction Stop
} catch {
    Write-Log "Error al leer o parsear 'config.json': $_" "ERROR"
    exit 1
}

$ExtractDir = $Config.ExtractDir
$SqlFilePrefix = $Config.SqlFilePrefix

if ([string]::IsNullOrEmpty($ExtractDir)) {
    Write-Log "Error: 'ExtractDir' no esta configurado en config.json." "ERROR"
    exit 1
}

if (!(Test-Path -Path $ExtractDir)) {
    Write-Log "Error: El directorio de extraccion '$ExtractDir' no existe." "ERROR"
    exit 1
}

$SqlPattern = if ([string]::IsNullOrEmpty($SqlFilePrefix)) { "*.sql" } else { "$SqlFilePrefix*.sql" }
$SqlCandidates = Get-ChildItem -Path $ExtractDir -Filter "*.sql" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like $SqlPattern } |
    Sort-Object LastWriteTime -Descending

if ($null -eq $SqlCandidates -or $SqlCandidates.Count -eq 0) {
    Write-Log "Error: No se encontro ningun archivo .sql con patron '$SqlPattern' en '$ExtractDir'." "ERROR"
    exit 1
}

$SqlFile = $SqlCandidates[0].FullName
Write-Log "Archivo SQL seleccionado: $SqlFile"
Write-Log "Motor configurado: mysql"

$DbHost = $Config.DbHost
$DbPort = if ([string]::IsNullOrEmpty($Config.DbPort)) { 3306 } else { $Config.DbPort }
$DbName = $Config.DbName
$DbUser = $Config.DbUser
$DbPassword = $Config.DbPassword
$MysqlPath = $Config.MysqlPath

$RequiredFields = @("DbHost", "DbName", "DbUser", "DbPassword")
foreach ($Field in $RequiredFields) {
    if ([string]::IsNullOrEmpty($Config.$Field) -or $Config.$Field -match "^CAMBIAR_POR_") {
        Write-Log "Error: El campo '$Field' no esta configurado correctamente." "ERROR"
        exit 1
    }
}

if ([string]::IsNullOrEmpty($MysqlPath) -or !(Test-Path -Path $MysqlPath)) {
    $CommonMysqlPaths = @(
        "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe",
        "C:\Program Files\MySQL\MySQL Server 5.7\bin\mysql.exe",
        "C:\xampp\mysql\bin\mysql.exe",
        "C:\wamp64\bin\mysql\mysql8.0.31\bin\mysql.exe"
    )
    foreach ($Path in $CommonMysqlPaths) {
        if (Test-Path -Path $Path) {
            $MysqlPath = $Path
            break
        }
    }
}

if ([string]::IsNullOrEmpty($MysqlPath) -or !(Test-Path -Path $MysqlPath)) {
    Write-Log "Error: No se encontro mysql.exe. Configura 'MysqlPath' en config.json." "ERROR"
    exit 1
}

$TempDropTriggers = Join-Path $ScriptDir "mysql_drop_triggers.sql"

try {
    $env:MYSQL_PWD = $DbPassword

    $ListTriggerArgs = @(
        "--host=$DbHost",
        "--port=$DbPort",
        "--user=$DbUser",
        "--database=information_schema",
        "--batch",
        "--skip-column-names",
        "--execute=SELECT CONCAT('DROP TRIGGER IF EXISTS ``', TRIGGER_SCHEMA, '``.``', TRIGGER_NAME, '``;') FROM TRIGGERS WHERE TRIGGER_SCHEMA = '$DbName';"
    )

    $DropTriggerStatements = & $MysqlPath @ListTriggerArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Error al consultar triggers existentes: $DropTriggerStatements" "ERROR"
        exit $LASTEXITCODE
    }

    $DropScriptLines = @("SET FOREIGN_KEY_CHECKS = 0;")

    foreach ($Stmt in $DropTriggerStatements) {
        if (![string]::IsNullOrWhiteSpace($Stmt)) {
            $DropScriptLines += $Stmt
        }
    }

    $DropScriptLines += "SET FOREIGN_KEY_CHECKS = 1;"
    Set-Content -Path $TempDropTriggers -Value $DropScriptLines -Encoding UTF8

    $BaseArguments = @(
        "--host=$DbHost",
        "--port=$DbPort",
        "--user=$DbUser",
        "--database=$DbName",
        "--default-character-set=utf8mb4"
    )

    # 1) Limpia triggers existentes en la base destino
    $DropProcess = Start-Process -FilePath $MysqlPath -ArgumentList $BaseArguments -RedirectStandardInput $TempDropTriggers -Wait -NoNewWindow -PassThru
    if ($DropProcess.ExitCode -ne 0) {
        Write-Log "Error al eliminar triggers existentes. Codigo de salida: $($DropProcess.ExitCode)" "ERROR"
        exit $DropProcess.ExitCode
    }

    # 2) Importa el dump SQL principal
    $Process = Start-Process -FilePath $MysqlPath -ArgumentList $BaseArguments -RedirectStandardInput $SqlFile -Wait -NoNewWindow -PassThru
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
} finally {
    if (Test-Path $TempDropTriggers) {
        Remove-Item $TempDropTriggers -Force
    }
}

if ($Process.ExitCode -ne 0) {
    Write-Log "Error en la importacion SQL. Codigo de salida: $($Process.ExitCode)" "ERROR"
    exit $Process.ExitCode
}

try {
    Remove-Item -Path $SqlFile -Force -ErrorAction Stop
    Write-Log "Archivo SQL eliminado despues de importar: $SqlFile"
} catch {
    Write-Log "Advertencia: la importacion fue exitosa, pero no se pudo eliminar el SQL: $_" "WARN"
}

Write-Log "Importacion SQL finalizada correctamente." "SUCCESS"
