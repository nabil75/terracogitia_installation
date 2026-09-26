<#
.SYNOPSIS
    Remove the Terra-Cogitia deployment from the Hetzner server.

.DESCRIPTION
    Strictly scoped to Terra-Cogitia (unlike the PlanningPowerTools "nuclear" mode, there is
    no global cleanup): runs cogitia-remote.sh clean, which removes
      - containers   Cogitia-FrontEnd, Cogitia-BackEnd, Cogitia-Database (by exact name)
      - network      NetCogitia (only if no foreign container is still attached)
      - images       label com.terra-cogitia.project=cogitia (+ the three image names)
      - files        <deploy_dir>/images/*.tar and <deploy_dir>/secrets
      - volumes      ONLY with -PurgeData (a pg_dump safety backup is taken first)
      - nginx vhost  ONLY with -RemoveNginx (certificates in /etc/letsencrypt are always kept)
    Database backups in <deploy_dir>/backups are never deleted.

    Handles partial deployments: containers already stopped or absent, network absent, etc.

.PARAMETER PurgeData
    Also delete the data volumes (production database, uploaded audio/media).

.PARAMETER RemoveNginx
    Also remove the host nginx vhost (app./api. domains).

.PARAMETER KeepImages
    Keep the Terra-Cogitia images on the server.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER RegistryPath
    Alternative registry file (default: cogitia-registry.json next to this script).

.EXAMPLE
    .\clean-all.ps1
    .\clean-all.ps1 -KeepImages -Force
    .\clean-all.ps1 -PurgeData -RemoveNginx
#>

[CmdletBinding()]
param(
    [switch]$PurgeData,
    [switch]$RemoveNginx,
    [switch]$KeepImages,
    [switch]$Force,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

$exitCode = 0
$session = $null
try {
    Write-CogitiaBanner 'Terra-Cogitia -- Cleanup on Hetzner'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    $prod = Get-CogitiaEnvironment $registry 'production'
    $stagingDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.runtime_dir) 'production'

    Write-Host "  Server:     $($prod.server.user)@$($prod.server.host):$($prod.server.deploy_dir)" -ForegroundColor Cyan
    Write-Host "  Containers: $((Get-CogitiaServices $registry | ForEach-Object { $_.Container }) -join ', ')" -ForegroundColor Cyan
    Write-Host "  Network:    $($registry.network_name)" -ForegroundColor Cyan
    Write-Host "  Images:     $(if ($KeepImages) { 'kept' } else { 'removed' })" -ForegroundColor Cyan
    Write-Host "  Volumes:    $(if ($PurgeData) { 'DELETED (after a safety backup)' } else { 'kept' })" -ForegroundColor $(if ($PurgeData) { 'Red' } else { 'Cyan' })
    Write-Host "  nginx:      $(if ($RemoveNginx) { 'vhost removed' } else { 'kept' })" -ForegroundColor Cyan

    $session = New-CogitiaSshSession $prod.server
    $remoteScript = Sync-CogitiaRemoteTooling -Session $session -Registry $registry -StagingDir $stagingDir

    Write-CogitiaPhase 'Current state'
    Invoke-CogitiaRemote $session "bash $remoteScript status" -Indent '  ' | Out-Null

    if (-not $Force) {
        Write-Host ""
        if ($PurgeData) {
            Write-Host "  -PurgeData permanently deletes the PRODUCTION database and media volumes." -ForegroundColor Red
            $ok = (Read-Host "  Type 'cogitia' to confirm") -eq 'cogitia'
        } else {
            $ok = (Read-Host "  Remove the Terra-Cogitia deployment from $($prod.server.host)? [y/N]") -in @('y', 'Y', 'yes')
        }
        if (-not $ok) {
            Write-CogitiaWarn 'Aborted by user -- nothing removed.'
            exit 0
        }
    }

    Write-CogitiaPhase 'Cleaning'
    $flags = @()
    if ($PurgeData)   { $flags += '--purge-data' }
    if ($RemoveNginx) { $flags += '--remove-nginx' }
    if ($KeepImages)  { $flags += '--keep-images' }
    Invoke-CogitiaRemote $session "bash $remoteScript clean $($flags -join ' ')" -Indent '  ' -DisplayName 'Remote cleanup' | Out-Null

    Write-CogitiaPhase 'Remaining Terra-Cogitia state'
    Invoke-CogitiaRemote $session "bash $remoteScript status" -Indent '  ' | Out-Null

    Write-CogitiaBanner 'Cleanup on Hetzner Complete'
}
catch {
    Write-CogitiaFail $_.Exception.Message
    $exitCode = 1
}
finally {
    Close-CogitiaSshSession $session
}
exit $exitCode
