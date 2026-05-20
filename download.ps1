# ==============================================================================
# Script de Descarga de Backup por FTP
# ==============================================================================
# Este script se conecta a un servidor FTP/SFTP remoto y descarga un archivo backup
# (.rar) especificado en config.json. Soporta WinSCP y descarga nativa de PowerShell.
# ==============================================================================

# Directorio del script y archivo de configuración
$ScriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.json"
$LogFile = Join-Path $ScriptDir "download.log"

# Función para escribir logs en pantalla y archivo
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

Write-Log "Iniciando proceso de descarga de copia de seguridad..."

# Verificar si el archivo de configuración existe
if (!(Test-Path -Path $ConfigFile)) {
    Write-Log "Error: No se encontró el archivo de configuración en '$ConfigFile'." "ERROR"
    Write-Log "Por favor, crea el archivo 'config.json' basado en 'config.json.template'." "ERROR"
    exit 1
}

# Cargar y parsear la configuración
try {
    $ConfigContent = Get-Content -Raw -Path $ConfigFile -ErrorAction Stop
    $Config = ConvertFrom-Json $ConfigContent -ErrorAction Stop
} catch {
    Write-Log "Error al leer o parsear el archivo 'config.json': $_" "ERROR"
    exit 1
}

# Validar campos requeridos
$RequiredFields = @("FtpHost", "FtpUser", "FtpPassword", "RemotePath", "LocalDir")
foreach ($Field in $RequiredFields) {
    if ([string]::IsNullOrEmpty($Config.$Field) -or $Config.$Field -match "^CAMBIAR_POR_") {
        Write-Log "Error: El campo '$Field' en config.json no está configurado correctamente." "ERROR"
        exit 1
    }
}

# Asignar variables
$FtpHost    = $Config.FtpHost
$FtpPort    = if ([string]::IsNullOrEmpty($Config.FtpPort)) { 21 } else { $Config.FtpPort }
$FtpUser    = $Config.FtpUser
$FtpPassword = $Config.FtpPassword
$Protocol   = if ([string]::IsNullOrEmpty($Config.Protocol)) { "ftp" } else { $Config.Protocol.ToLower() }
$RemotePath = $Config.RemotePath
$LocalDir   = $Config.LocalDir
$UseWinSCP  = if ($null -eq $Config.UseWinSCP) { $true } else { $Config.UseWinSCP }
$WinScpPath = $Config.WinScpPath

# Validar y crear directorio local si no existe
if (!(Test-Path -Path $LocalDir)) {
    try {
        New-Item -ItemType Directory -Path $LocalDir -Force -ErrorAction Stop | Out-Null
        Write-Log "Creado directorio local: $LocalDir" "INFO"
    } catch {
        Write-Log "Error al crear el directorio local '$LocalDir': $_" "ERROR"
        exit 1
    }
}

# Obtener nombre del archivo y ruta de destino local
$FileName = Split-Path -Leaf -Path $RemotePath
$LocalPath = Join-Path $LocalDir $FileName

Write-Log "Configuración cargada correctamente."
Write-Log "Servidor: $($FtpHost):$($FtpPort) ($Protocol)"
Write-Log "Archivo remoto: $RemotePath"
Write-Log "Destino local: $LocalPath"

# Decidir método de descarga
if ($UseWinSCP) {
    Write-Log "Usando WinSCP para la descarga..."

    # Verificar ruta del ejecutable de WinSCP
    if ([string]::IsNullOrEmpty($WinScpPath) -or !(Test-Path -Path $WinScpPath)) {
        # Intentar buscar en rutas comunes
        $CommonPaths = @(
            "C:\Program Files (x86)\WinSCP\WinSCP.exe",
            "C:\Program Files\WinSCP\WinSCP.exe",
            (Join-Path $env:LocalAppData "Programs\WinSCP\WinSCP.exe")
        )
        $Found = $false
        foreach ($Path in $CommonPaths) {
            if (Test-Path -Path $Path) {
                $WinScpPath = $Path
                $Found = $true
                break
            }
        }
        if (!$Found) {
            Write-Log "Error: No se encontró WinSCP en la ruta configurada ni en las ubicaciones estándar." "ERROR"
            Write-Log "Por favor instala WinSCP o cambia 'UseWinSCP' a false en config.json para usar descarga nativa." "ERROR"
            exit 1
        }
    }

    # Usar winscp.com si está disponible para redirección de consola, si no usar winscp.exe
    $WinScpBin = $WinScpPath
    if ($WinScpBin -match "\.exe$") {
        $WinScpCom = $WinScpBin -replace "\.exe$", ".com"
        if (Test-Path $WinScpCom) {
            $WinScpBin = $WinScpCom
        }
    }

    # Escapar credenciales para la URL de conexión de WinSCP
    $EscapedUser = [uri]::EscapeDataString($FtpUser)
    $EscapedPassword = [uri]::EscapeDataString($FtpPassword)
    $ConnString = "$($Protocol)://$($EscapedUser):$($EscapedPassword)@$($FtpHost):$($FtpPort)/"

    # Argumentos extras de seguridad según protocolo
    $ExtraArgs = ""
    if ($Protocol -eq "sftp") {
        $ExtraArgs = "-hostkey=*"
    } elseif ($Protocol -eq "ftps") {
        $ExtraArgs = "-certificate=*"
    }

    # Ejecutar comandos de WinSCP
    $WinScpArgs = @(
        "/command",
        "option batch abort",
        "option confirm off",
        "open `"$ConnString`" $ExtraArgs",
        "get `"$RemotePath`" `"$LocalPath`"",
        "exit"
    )

    Write-Log "Ejecutando WinSCP en: $WinScpBin"
    
    # Iniciar WinSCP y capturar código de salida
    $Process = Start-Process -FilePath $WinScpBin -ArgumentList $WinScpArgs -Wait -NoNewWindow -PassThru
    
    if ($Process.ExitCode -eq 0) {
        Write-Log "Descarga completada exitosamente vía WinSCP." "SUCCESS"
    } else {
        Write-Log "Error al descargar con WinSCP. Código de salida del proceso: $($Process.ExitCode)" "ERROR"
        Write-Log "Revisa los logs o intenta usar la conexión nativa configurando 'UseWinSCP': false en config.json." "ERROR"
        exit $Process.ExitCode
    }

} else {
    # Descarga nativa (Solo FTP tradicional, no SFTP/FTPS nativo en .NET FtpWebRequest de forma simple sin certificados)
    Write-Log "Usando descarga FTP nativa de PowerShell..."
    
    if ($Protocol -ne "ftp") {
        Write-Log "Advertencia: El protocolo nativo de .NET FtpWebRequest solo soporta FTP plano. Intentando conexión FTP..." "WARN"
    }

    try {
        # Formatear la URL FTP
        # Quitar barra inicial si RemotePath empieza con ella para no duplicar en la URI
        $PathClean = $RemotePath.TrimStart("/")
        $FtpUrl = New-Object System.Uri("ftp://$($FtpHost):$($FtpPort)/$PathClean")
        
        $Request = [System.Net.FtpWebRequest]::Create($FtpUrl)
        $Request.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPassword)
        $Request.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $Request.UseBinary = $true
        $Request.KeepAlive = $false
        
        Write-Log "Conectando a $FtpUrl..."
        $Response = $Request.GetResponse()
        $ResponseStream = $Response.GetResponseStream()
        
        # Guardar en archivo local
        $LocalStream = [System.IO.File]::Create($LocalPath)
        $Buffer = New-Object Byte[] 10240
        
        Write-Log "Descargando datos..."
        while (($Read = $ResponseStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $LocalStream.Write($Buffer, 0, $Read)
        }
        
        # Cerrar flujos
        $LocalStream.Close()
        $ResponseStream.Close()
        $Response.Close()
        
        Write-Log "Descarga nativa FTP completada exitosamente." "SUCCESS"
        
    } catch {
        Write-Log "Error durante la descarga nativa por FTP: $_" "ERROR"
        exit 1
    }
}

Write-Log "Proceso de backup finalizado con éxito."
# ==============================================================================
