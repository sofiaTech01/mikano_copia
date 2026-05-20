# ==============================================================================
# Script de Descompresion de Backup (.rar)
# ==============================================================================
# Este script busca en LocalDir el backup .rar del dia (segun FilePrefix) y lo
# descomprime en un directorio de salida usando 7-Zip o RAR/WinRAR.
# ==============================================================================

$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogFile = Join-Path $ScriptDir "extract.log"

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

Write-Log "Iniciando proceso de descompresion..."

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

$LocalDir = $Config.LocalDir
$FilePrefix = $Config.FilePrefix
$ExtractDir = if ([string]::IsNullOrEmpty($Config.ExtractDir)) { (Join-Path $LocalDir "extracted") } else { $Config.ExtractDir }
$ArchiverPath = $Config.ArchiverPath

if ([string]::IsNullOrEmpty($LocalDir)) {
    Write-Log "Error: 'LocalDir' no esta configurado en config.json." "ERROR"
    exit 1
}

if (!(Test-Path -Path $LocalDir)) {
    Write-Log "Error: El directorio local '$LocalDir' no existe." "ERROR"
    exit 1
}

if (!(Test-Path -Path $ExtractDir)) {
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    Write-Log "Creado directorio de extraccion: $ExtractDir"
}

$DateStr = Get-Date -Format "yyyy_MM_dd"
$Pattern = if ([string]::IsNullOrEmpty($FilePrefix)) { "*.rar" } else { "$($FilePrefix)$($DateStr)*.rar" }

$Candidates = Get-ChildItem -Path $LocalDir -Filter "*.rar" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like $Pattern } |
    Sort-Object LastWriteTime -Descending

if ($null -eq $Candidates -or $Candidates.Count -eq 0) {
    Write-Log "Error: No se encontro ningun archivo .rar con patron '$Pattern' en '$LocalDir'." "ERROR"
    exit 1
}

$ArchiveFile = $Candidates[0].FullName
$TargetDir = $ExtractDir

Write-Log "Archivo seleccionado: $ArchiveFile"
Write-Log "Destino de extraccion: $TargetDir"

if ([string]::IsNullOrEmpty($ArchiverPath) -or !(Test-Path -Path $ArchiverPath)) {
    $CommonArchivers = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe",
        "C:\kopiaz\web\programas_no_borrar\Rar.exe",
        "C:\Program Files\WinRAR\WinRAR.exe",
        "C:\Program Files (x86)\WinRAR\WinRAR.exe"
    )

    foreach ($Path in $CommonArchivers) {
        if (Test-Path -Path $Path) {
            $ArchiverPath = $Path
            break
        }
    }
}

if ([string]::IsNullOrEmpty($ArchiverPath) -or !(Test-Path -Path $ArchiverPath)) {
    Write-Log "Error: No se encontro 7-Zip ni RAR/WinRAR. Configura 'ArchiverPath' en config.json." "ERROR"
    exit 1
}

Write-Log "Compresor detectado: $ArchiverPath"

$ArchiverExeName = [System.IO.Path]::GetFileName($ArchiverPath).ToLower()

if ($ArchiverExeName -eq "7z.exe") {
    # "e" extrae sin conservar carpetas internas del archivo
    $Arguments = @("e", "-y", "-o$TargetDir", $ArchiveFile)
    $Process = Start-Process -FilePath $ArchiverPath -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
} elseif ($ArchiverExeName -eq "winrar.exe" -or $ArchiverExeName -eq "rar.exe") {
    # "e" extrae sin conservar carpetas internas del archivo
    $Arguments = @("e", "-y", $ArchiveFile, "$TargetDir\")
    $Process = Start-Process -FilePath $ArchiverPath -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
} else {
    Write-Log "Error: ArchiverPath no corresponde a 7z.exe, Rar.exe o WinRAR.exe." "ERROR"
    exit 1
}

if ($Process.ExitCode -ne 0) {
    Write-Log "Error al descomprimir. Codigo de salida: $($Process.ExitCode)" "ERROR"
    exit $Process.ExitCode
}

Write-Log "Descompresion finalizada correctamente." "SUCCESS"
