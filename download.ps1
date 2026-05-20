# ==============================================================================
# Script de Descarga de Backup Dinámico por FTP
# ==============================================================================
# Este script se conecta a un servidor FTP/SFTP remoto y descarga la copia de seguridad
# del día actual basada en un patrón dinámico (ej. TOT_PrdCol_YYYY_MM_DD*.rar).
# Soporta automatización mediante WinSCP y descarga nativa de PowerShell (.NET).
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

Write-Log "Iniciando proceso de descarga de copia de seguridad diaria..."

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

# Validar campos básicos requeridos
$RequiredFields = @("FtpHost", "FtpUser", "FtpPassword", "LocalDir")
foreach ($Field in $RequiredFields) {
    if ([string]::IsNullOrEmpty($Config.$Field) -or $Config.$Field -match "^CAMBIAR_POR_") {
        Write-Log "Error: El campo '$Field' en config.json no está configurado correctamente." "ERROR"
        exit 1
    }
}

# Asignar variables principales
$FtpHost     = $Config.FtpHost
$FtpPort     = if ([string]::IsNullOrEmpty($Config.FtpPort)) { 21 } else { $Config.FtpPort }
$FtpUser     = $Config.FtpUser
$FtpPassword = $Config.FtpPassword
$Protocol    = if ([string]::IsNullOrEmpty($Config.Protocol)) { "ftp" } else { $Config.Protocol.ToLower() }
$LocalDir    = $Config.LocalDir
$UseWinSCP   = if ($null -eq $Config.UseWinSCP) { $true } else { $Config.UseWinSCP }
$WinScpPath  = $Config.WinScpPath

# Cargar configuración de rutas
$RemoteDir   = if ([string]::IsNullOrEmpty($Config.RemoteDir)) { "./" } else { $Config.RemoteDir }
$FilePrefix  = $Config.FilePrefix
$RemotePath  = $Config.RemotePath # Mantener compatibilidad estática

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

# Determinar si es descarga dinámica (por fecha) o estática (archivo fijo)
$IsDynamic = ![string]::IsNullOrEmpty($FilePrefix)
$SearchPattern = ""

if ($IsDynamic) {
    # Formatear la fecha actual: AÑO_MES_DIA (ej. 2026_05_20)
    $DateStr = Get-Date -Format "yyyy_MM_dd"
    $SearchPattern = "$($FilePrefix)$($DateStr)*.rar"
    Write-Log "Modo dinámico activo. Buscando copia del día: $SearchPattern"
} else {
    if ([string]::IsNullOrEmpty($RemotePath) -or $RemotePath -match "^CAMBIAR_POR_") {
        Write-Log "Error: Configura 'RemoteDir' y 'FilePrefix' para búsqueda dinámica, o 'RemotePath' para archivo estático." "ERROR"
        exit 1
    }
    Write-Log "Modo estático activo. Archivo fijo a descargar: $RemotePath"
}

Write-Log "Configuración cargada correctamente."
Write-Log "Servidor: $($FtpHost):$($FtpPort) ($Protocol)"
Write-Log "Directorio local de descarga: $LocalDir"

# Decidir método de descarga
if ($UseWinSCP) {
    Write-Log "Método seleccionado: WinSCP"

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

    # Asegurar que el directorio local termina en barra para que WinSCP lo reconozca como destino de carpeta
    $LocalDirTarget = if ($LocalDir.EndsWith("\")) { $LocalDir } else { "$LocalDir\" }

    # Definir ruta de origen remoto (con patrón dinámico o ruta estática)
    $RemoteSource = ""
    if ($IsDynamic) {
        # Combinar RemoteDir y el patrón de búsqueda
        if ([string]::IsNullOrEmpty($RemoteDir)) {
            $RemoteSource = $SearchPattern
        } elseif ($RemoteDir.EndsWith("/")) {
            $RemoteSource = "$RemoteDir$SearchPattern"
        } else {
            $RemoteSource = "$RemoteDir/$SearchPattern"
        }
    } else {
        $RemoteSource = $RemotePath
    }

    # Crear script temporal para WinSCP para evitar problemas de escape en la línea de comandos
    $ScriptFile = Join-Path $ScriptDir "winscp_commands.txt"
    try {
        $ScriptContent = @"
option batch abort
option confirm off
open "$ConnString" $ExtraArgs
get "$RemoteSource" "$LocalDirTarget"
exit
"@
        Set-Content -Path $ScriptFile -Value $ScriptContent -Force -Encoding UTF8
        
        Write-Log "Ejecutando WinSCP en: $WinScpBin"
        Write-Log "Comando de descarga: get `"$RemoteSource`" `"$LocalDirTarget`""
        
        # Iniciar WinSCP con el script temporal
        $Process = Start-Process -FilePath $WinScpBin -ArgumentList "/script=`"$ScriptFile`"" -Wait -NoNewWindow -PassThru
        
        if ($Process.ExitCode -eq 0) {
            Write-Log "Descarga completada exitosamente vía WinSCP." "SUCCESS"
        } else {
            Write-Log "Error al descargar con WinSCP. Código de salida del proceso: $($Process.ExitCode)" "ERROR"
            Write-Log "Posibles razones: El archivo no existe aún en el FTP, o fallaron las credenciales." "ERROR"
            exit $Process.ExitCode
        }
    } finally {
        # Asegurar la eliminación del archivo temporal con la contraseña
        if (Test-Path $ScriptFile) {
            Remove-Item $ScriptFile -Force | Out-Null
        }
    }

} else {
    # Descarga nativa (Solo FTP tradicional, no SFTP/FTPS nativo en .NET FtpWebRequest de forma simple sin certificados)
    Write-Log "Método seleccionado: FTP Nativo (.NET FtpWebRequest)"
    
    if ($Protocol -ne "ftp") {
        Write-Log "Advertencia: El protocolo nativo solo soporta FTP plano. Intentando conexión FTP..." "WARN"
    }

    $RemoteFilePath = ""
    $LocalPath = ""

    try {
        if ($IsDynamic) {
            # Listar directorio FTP para buscar archivos coincidentes
            $PathClean = if (![string]::IsNullOrEmpty($RemoteDir)) { $RemoteDir.TrimStart("/") } else { "" }
            $FtpUrl = New-Object System.Uri("ftp://$($FtpHost):$($FtpPort)/$PathClean")
            
            $Request = [System.Net.FtpWebRequest]::Create($FtpUrl)
            $Request.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPassword)
            $Request.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
            $Request.KeepAlive = $false
            
            Write-Log "Listando directorio remoto para buscar el archivo de hoy: $FtpUrl"
            $Response = $Request.GetResponse()
            $Reader = New-Object System.IO.StreamReader($Response.GetResponseStream())
            $Files = $Reader.ReadToEnd() -split "`r?`n"
            $Reader.Close()
            $Response.Close()
            
            # Buscar coincidencia
            $MatchingFiles = $Files | Where-Object { 
                $name = Split-Path -Leaf $_
                $name.Trim() -like $SearchPattern
            }
            
            if ($null -eq $MatchingFiles -or $MatchingFiles.Count -eq 0) {
                Write-Log "Error: No se encontró ningún archivo con el patrón '$SearchPattern' en el servidor remoto." "ERROR"
                exit 1
            }
            
            # Tomar el primer archivo coincidente
            $TargetFile = $MatchingFiles[0].Trim()
            $RemoteFilePath = if ($TargetFile -match "^/") { $TargetFile } else { 
                if ($RemoteDir.EndsWith("/")) { "$RemoteDir$TargetFile" } else { "$RemoteDir/$TargetFile" }
            }
            $LocalPath = Join-Path $LocalDir (Split-Path -Leaf $TargetFile)
            
            Write-Log "Archivo diario encontrado en servidor: $TargetFile"
        } else {
            $RemoteFilePath = $RemotePath
            $LocalPath = Join-Path $LocalDir (Split-Path -Leaf $RemotePath)
        }

        # Proceder a descargar el archivo específico
        $PathClean = $RemoteFilePath.TrimStart("/")
        $DownloadUrl = New-Object System.Uri("ftp://$($FtpHost):$($FtpPort)/$PathClean")
        
        Write-Log "Iniciando descarga de $DownloadUrl hacia $LocalPath..."
        
        $Request = [System.Net.FtpWebRequest]::Create($DownloadUrl)
        $Request.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPassword)
        $Request.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $Request.UseBinary = $true
        $Request.KeepAlive = $false
        
        $Response = $Request.GetResponse()
        $ResponseStream = $Response.GetResponseStream()
        
        # Flujo de escritura local
        $LocalStream = [System.IO.File]::Create($LocalPath)
        $Buffer = New-Object Byte[] 10240
        
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
