<#
.SYNOPSIS
    Remove the local Terra-Cogitia deployment from Docker Desktop.

.DESCRIPTION
    Strictly scoped to Terra-Cogitia -- no global prune, other projects are never touched:
      - containers   Cogitia-FrontEnd, Cogitia-BackEnd, Cogitia-Database (by exact name)
      - network      NetCogitia (only if no foreign container is still attached)
      - images       every image carrying the registry label com.terra-cogitia.project=cogitia
      - artifacts    .runtime\local and exports\*.tar
      - volumes      ONLY with -PurgeData (database + Back-End media); a backup is taken first

    Kept: secrets.local.env and backups\. Safe to run when nothing (or only part) is deployed.

.PARAMETER PurgeData
    Also delete the data volumes (database content, uploaded audio/media). Asks for confirmation.

.PARAMETER KeepImages
    Keep the Terra-Cogitia images (faster redeploy with deploy-local.ps1 -SkipBuild).

.PARAMETER Force
    Do not ask for confirmation (with -PurgeData).

.PARAMETER RegistryPath
    Alternative registry file (default: cogitia-registry.json next to this script).

.EXAMPLE
    .\clean-all-local.ps1
    .\clean-all-local.ps1 -KeepImages
    .\clean-all-local.ps1 -PurgeData
#>

[CmdletBinding()]
param(
    [switch]$PurgeData,
    [switch]$KeepImages,
    [switch]$Force,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

function Get-CogitiaImageIds {
    $ids = @((Invoke-CogitiaNative docker @('images', '-q', '--filter', "label=$($registry.image_label)") -Quiet).Output | Where-Object { $_ })
    foreach ($svc in $services) {
        $r = Invoke-CogitiaNative docker @('image', 'inspect', '-f', '{{.Id}}', $svc.Image) -AllowFailure -Quiet
        if ($r.ExitCode -eq 0) { $ids += ($r.Output -join '').Trim() }
    }
    return @($ids | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-ExistingVolumes {
    @($volumes | Where-Object { (Invoke-CogitiaNative docker @('volume', 'inspect', $_) -AllowFailure -Quiet).ExitCode -eq 0 })
}

$exitCode = 0
try {
    Write-CogitiaBanner 'Terra-Cogitia -- Local Cleanup'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    Assert-CogitiaDocker | Out-Null
    $services   = @(Get-CogitiaServices $registry -All)
    $containers = @($services | ForEach-Object { $_.Container })
    $volumes    = @($registry.services.database.volume, $registry.services.backend.volume)

    Write-Host "  Containers: $($containers -join ', ')" -ForegroundColor Cyan
    Write-Host "  Network:    $($registry.network_name)" -ForegroundColor Cyan
    Write-Host "  Images:     $(if ($KeepImages) { 'kept' } else { "label $($registry.image_label)" })" -ForegroundColor Cyan
    Write-Host "  Volumes:    $(if ($PurgeData) { "DELETE $($volumes -join ', ')" } else { 'kept (use -PurgeData to delete)' })" -ForegroundColor $(if ($PurgeData) { 'Red' } else { 'Cyan' })

    if ($PurgeData -and -not $Force) {
        Write-Host ""
        Write-Host "  -PurgeData permanently deletes the local Terra-Cogitia database and media." -ForegroundColor Red
        if ((Read-Host "  Type 'cogitia' to confirm") -ne 'cogitia') {
            Write-CogitiaWarn 'Aborted by user -- nothing removed.'
            exit 0
        }
    }

    Write-CogitiaPhase 'Cleaning'

    if ($PurgeData -and (Get-CogitiaContainerState $registry.services.database.container_name) -like 'running/*') {
        $backupDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.backup_dir) 'local'
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $name = "cogitia_$($registry.database.name)_prepurge_$(Get-Date -Format 'yyyyMMdd_HHmmss').dump"
        $db = $registry.services.database.container_name
        Invoke-CogitiaNative docker @('exec', $db, 'pg_dump', '-U', $registry.database.user, '-d', $registry.database.name, '-Fc', '-f', "/tmp/$name") -Quiet -DisplayName 'pg_dump' | Out-Null
        Invoke-CogitiaNative docker @('cp', "${db}:/tmp/$name", (Join-Path $backupDir $name)) -Quiet -DisplayName 'docker cp (backup)' | Out-Null
        Write-CogitiaOk "Safety backup before purge: $(Join-Path $backupDir $name)"
    }

    foreach ($c in $containers) {
        if ((Get-CogitiaContainerState $c) -eq 'missing') { Write-CogitiaInfo "container $c -- not present"; continue }
        Invoke-CogitiaNative docker @('rm', '-f', $c) -Quiet | Out-Null
        Write-CogitiaOk "container $c removed"
    }

    $members = Get-CogitiaNetworkMembers $registry.network_name
    if ($null -eq $members) {
        Write-CogitiaInfo "network $($registry.network_name) -- not present"
    } elseif (@($members).Count -gt 0) {
        Write-CogitiaWarn "network $($registry.network_name) kept: still used by $($members -join ', ')"
    } else {
        Invoke-CogitiaNative docker @('network', 'rm', $registry.network_name) -Quiet | Out-Null
        Write-CogitiaOk "network $($registry.network_name) removed"
    }

    if ($PurgeData) {
        foreach ($v in Get-ExistingVolumes) {
            Invoke-CogitiaNative docker @('volume', 'rm', $v) -Quiet | Out-Null
            Write-CogitiaOk "volume $v removed"
        }
    }

    if (-not $KeepImages) {
        $ids = @(Get-CogitiaImageIds)
        if ($ids.Count -eq 0) { Write-CogitiaInfo 'images -- none present' }
        foreach ($id in $ids) {
            Invoke-CogitiaNative docker @('rmi', '-f', $id) -Quiet | Out-Null
        }
        if ($ids.Count -gt 0) { Write-CogitiaOk "$($ids.Count) Terra-Cogitia image(s) removed" }
    }

    foreach ($artifact in @((Join-Path (Resolve-CogitiaPath $registry $registry.paths.runtime_dir) 'local'),
                            (Resolve-CogitiaPath $registry $registry.paths.export_dir))) {
        if (Test-Path $artifact) {
            Remove-Item $artifact -Recurse -Force
            Write-CogitiaOk "artifacts $artifact removed"
        }
    }

    # --- Verification -----------------------------------------------------------
    Write-CogitiaPhase 'Verification'
    $checks = @()
    foreach ($c in $containers) {
        $checks += New-CogitiaCheck "container $c absent" ((Get-CogitiaContainerState $c) -eq 'missing') ''
    }
    $netLeft = Get-CogitiaNetworkMembers $registry.network_name
    $checks += New-CogitiaCheck "network $($registry.network_name) absent" ($null -eq $netLeft) $(if ($null -ne $netLeft) { 'still present (in use by other containers)' } else { '' }) -Warning
    if (-not $KeepImages) {
        $left = @(Get-CogitiaImageIds)
        $checks += New-CogitiaCheck 'Terra-Cogitia images absent' ($left.Count -eq 0) $(if ($left) { $left -join ', ' } else { '' })
    }
    $volLeft = @(Get-ExistingVolumes)
    if ($PurgeData) {
        $checks += New-CogitiaCheck 'data volumes absent' ($volLeft.Count -eq 0) ($volLeft -join ', ')
    } else {
        $checks += New-CogitiaCheck 'data volumes preserved' $true $(if ($volLeft) { $volLeft -join ', ' } else { '(none existed)' })
    }
    $failures = Write-CogitiaChecks $checks
    if ($failures -gt 0) { throw "$failures cleanup check(s) failed" }

    Write-CogitiaBanner 'Local Cleanup Complete'
}
catch {
    Write-CogitiaFail $_.Exception.Message
    $exitCode = 1
}
exit $exitCode
