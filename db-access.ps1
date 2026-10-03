<#
.SYNOPSIS
    Accès pratique à la base Terra-Cogitia locale (Docker Desktop).

.DESCRIPTION
    PostgreSQL n'est pas publié hors de NetCogitia. Ce script ouvre un accès local :

      (défaut)  Interface web Adminer  →  http://127.0.0.1:8210
      -Shell    Session interactive psql dans Cogitia-Database
      -Tunnel   Tunnel TCP 127.0.0.1:15432 pour DBeaver / pgAdmin / etc.
      -Stop     Arrête Adminer et le tunnel

.PARAMETER Shell
    Ouvre psql interactif (pas de mot de passe : socket local dans le conteneur).

.PARAMETER Tunnel
    Expose PostgreSQL sur 127.0.0.1 (port -TunnelPort, défaut 5433) via un conteneur socat jetable.

.PARAMETER Stop
    Arrête Cogitia-Adminer et Cogitia-DbTunnel s'ils tournent.

.PARAMETER Port
    Port local d'Adminer (défaut 8210).

.PARAMETER TunnelPort
    Port local du tunnel TCP (défaut 15432 ; 5432/5433 sont souvent indisponibles sous Windows/Docker).

.PARAMETER NoBrowser
    N'ouvre pas le navigateur après le démarrage d'Adminer.

.PARAMETER RegistryPath
    Registry alternatif (défaut : cogitia-registry.json).

.EXAMPLE
    .\db-access.ps1
    .\db-access.ps1 -Shell
    .\db-access.ps1 -Tunnel
    .\db-access.ps1 -Stop
#>

[CmdletBinding(DefaultParameterSetName = 'Ui')]
param(
    [Parameter(ParameterSetName = 'Shell')][switch]$Shell,
    [Parameter(ParameterSetName = 'Tunnel')][switch]$Tunnel,
    [Parameter(ParameterSetName = 'Stop')][switch]$Stop,
    [Parameter(ParameterSetName = 'Ui')][ValidateRange(1024, 65535)][int]$Port = 8210,
    [Parameter(ParameterSetName = 'Tunnel')][ValidateRange(1024, 65535)][int]$TunnelPort = 15432,
    [Parameter(ParameterSetName = 'Ui')][switch]$NoBrowser,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

$adminerName = 'Cogitia-Adminer'
$tunnelName  = 'Cogitia-DbTunnel'

function Stop-CogitiaHelper {
    param([string]$Name)
    $state = Get-CogitiaContainerState $Name
    if ($state -eq 'missing') {
        Write-CogitiaInfo "$Name already stopped"
        return
    }
    Invoke-CogitiaNative docker @('rm', '-f', $Name) -Quiet -DisplayName "docker rm -f $Name" | Out-Null
    Write-CogitiaOk "Stopped $Name"
}

try {
    Write-CogitiaBanner 'Terra-Cogitia -- Database Access'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    $envCfg = Get-CogitiaEnvironment $registry 'local'
    $db = $registry.services.database
    Assert-CogitiaDocker | Out-Null

    if ($Stop) {
        Write-CogitiaPhase 'Stop helpers'
        Stop-CogitiaHelper $adminerName
        Stop-CogitiaHelper $tunnelName
        return
    }

    $dbState = Get-CogitiaContainerState $db.container_name
    if ($dbState -notlike 'running/*') {
        throw "$($db.container_name) is not running ($dbState). Start it with: .\deploy-local.ps1 -SkipBuild"
    }

    if ($Shell) {
        Write-CogitiaPhase 'Interactive psql'
        Write-CogitiaInfo "Database: $($registry.database.name)  User: $($registry.database.user)"
        Write-CogitiaStep "Entering $($db.container_name) (exit with \q)"
        # Interactive: do not capture stdout.
        & docker exec -it $db.container_name psql -U $registry.database.user -d $registry.database.name
        if ($LASTEXITCODE -ne 0) { throw "psql exited with code $LASTEXITCODE" }
        return
    }

    if ($Tunnel) {
        Write-CogitiaPhase "TCP tunnel 127.0.0.1:$TunnelPort"
        if ((Get-CogitiaContainerState $tunnelName) -ne 'missing') {
            Write-CogitiaOk "$tunnelName already running"
        } else {
            Invoke-CogitiaNative docker @(
                'run', '-d', '--rm',
                '--name', $tunnelName,
                '--network', $registry.network_name,
                '-p', "127.0.0.1:${TunnelPort}:5432",
                'alpine/socat',
                'TCP-LISTEN:5432,fork,reuseaddr',
                "TCP:$($db.alias):5432"
            ) -DisplayName "start $tunnelName" | Out-Null
            Write-CogitiaOk "Tunnel started"
        }

        $secretsPath = Resolve-CogitiaPath $registry $envCfg.secrets_file
        Write-Host ""
        Write-Host "  Connect with DBeaver / pgAdmin / Azure Data Studio:" -ForegroundColor Cyan
        Write-Host "    Host:     127.0.0.1"
        Write-Host "    Port:     $TunnelPort"
        Write-Host "    Database: $($registry.database.name)"
        Write-Host "    User:     $($registry.database.user)"
        Write-Host "    Password: POSTGRES_PASSWORD in $($envCfg.secrets_file)"
        if (Test-Path $secretsPath) {
            Write-CogitiaInfo "Secrets file: $secretsPath"
        }
        Write-Host ""
        Write-CogitiaInfo "Stop with:  .\db-access.ps1 -Stop"
        return
    }

    # --- Default: Adminer UI -------------------------------------------------
    Write-CogitiaPhase "Adminer on http://127.0.0.1:$Port"
    if ((Get-CogitiaContainerState $adminerName) -ne 'missing') {
        Write-CogitiaOk "$adminerName already running"
    } else {
        Invoke-CogitiaNative docker @(
            'run', '-d', '--rm',
            '--name', $adminerName,
            '--network', $registry.network_name,
            '-p', "127.0.0.1:${Port}:8080",
            'adminer:latest'
        ) -DisplayName "start $adminerName" | Out-Null
        Write-CogitiaOk "Adminer started"
    }

    $url = "http://127.0.0.1:$Port"
    $secretsPath = Resolve-CogitiaPath $registry $envCfg.secrets_file
    Write-Host ""
    Write-Host "  Open $url and connect with:" -ForegroundColor Cyan
    Write-Host "    System:   PostgreSQL"
    Write-Host "    Server:   $($db.alias)"
    Write-Host "    Username: $($registry.database.user)"
    Write-Host "    Password: POSTGRES_PASSWORD in $($envCfg.secrets_file)"
    Write-Host "    Database: $($registry.database.name)"
    if (Test-Path $secretsPath) {
        Write-CogitiaInfo "Secrets file: $secretsPath"
    }
    Write-Host ""
    Write-CogitiaInfo "Stop with:  .\db-access.ps1 -Stop"

    if (-not $NoBrowser) {
        Start-Process $url
    }
}
catch {
    Write-CogitiaFail $_.Exception.Message
    exit 1
}
