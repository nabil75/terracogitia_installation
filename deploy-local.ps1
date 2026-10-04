<#
.SYNOPSIS
    Build and (re)deploy Terra-Cogitia locally on Docker Desktop.

.DESCRIPTION
    Idempotent local deployment -- safe to run repeatedly:
      Phase 1: Prerequisites (Docker engine, compose v2, buildx, sources, registry, secrets)
      Phase 2: Build images  cogitia-database / cogitia-backend / cogitia-frontend
      Phase 3: Runtime configuration (.runtime\cogitia.env + .runtime\secrets\*.env)
      Phase 4: Deploy -- database backup, NetCogitia network, stray-container removal,
               docker compose up (recreates only what changed; data volumes are kept)
      Phase 5: Wait until all three containers report healthy
      Phase 6: Verification (endpoints, database, CORS, NetCogitia connectivity, restart policy)
      Phase 7: Remove dangling Terra-Cogitia images (label-scoped, never global)

    Endpoints:  Front-End http://localhost:8200   Back-End http://localhost:8201
    Only Terra-Cogitia resources are touched (container names, NetCogitia, image label).

.PARAMETER NoCache
    Pass --no-cache to docker build.

.PARAMETER SkipBuild
    Reuse the existing local images (fails if they do not exist).

.PARAMETER SkipBackup
    Do not dump the database before redeploying.

.PARAMETER HealthTimeoutSec
    Maximum wait for healthy containers (default 300).

.PARAMETER SyncDbPassword
    Set the database's password to POSTGRES_PASSWORD from secrets.local.env, keeping all data.
    Use when the Back-End fails with "password authentication failed": the database volume
    was created with an earlier password (e.g. secrets.local.env was lost or regenerated).

.PARAMETER RegistryPath
    Alternative registry file (default: cogitia-registry.json next to this script).

.EXAMPLE
    .\deploy-local.ps1
    .\deploy-local.ps1 -NoCache
    .\deploy-local.ps1 -SkipBuild
    .\deploy-local.ps1 -SyncDbPassword    # fix a password mismatch, data kept
#>

[CmdletBinding()]
param(
    [switch]$NoCache,
    [switch]$SkipBuild,
    [switch]$SkipBackup,
    [switch]$SyncDbPassword,
    [ValidateRange(30, 1800)][int]$HealthTimeoutSec = 300,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

function Invoke-LocalCompose {
    param([string[]]$Arguments)
    $composeArgs = @('compose', '-p', $registry.compose_project,
                     '--project-directory', $runtimeDir,
                     '--env-file', (Join-Path $runtimeDir 'cogitia.env'),
                     '-f', $composeFile) + $Arguments
    Invoke-CogitiaNative docker $composeArgs -DisplayName "docker compose $($Arguments -join ' ')" | Out-Null
}

function Backup-LocalDatabase {
    $db = $registry.services.database
    if ((Get-CogitiaContainerState $db.container_name) -notlike 'running/*') {
        Write-CogitiaInfo "Backup skipped: $($db.container_name) not running (first deployment?)"
        return
    }
    $backupDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.backup_dir) 'local'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $name = "cogitia_$($registry.database.name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').dump"
    $inContainer = "/tmp/$name"
    # pg_dump inside the container + docker cp: PowerShell pipes would corrupt the binary dump.
    Invoke-CogitiaNative docker @('exec', $db.container_name, 'pg_dump', '-U', $registry.database.user, '-d', $registry.database.name, '-Fc', '-f', $inContainer) -Quiet -DisplayName 'pg_dump' | Out-Null
    Invoke-CogitiaNative docker @('cp', "$($db.container_name):$inContainer", (Join-Path $backupDir $name)) -Quiet -DisplayName 'docker cp (backup)' | Out-Null
    Invoke-CogitiaNative docker @('exec', $db.container_name, 'rm', '-f', $inContainer) -AllowFailure -Quiet | Out-Null
    $sizeKB = [math]::Round((Get-Item (Join-Path $backupDir $name)).Length / 1KB, 1)
    Write-CogitiaOk "Database backup: $(Join-Path $backupDir $name) ($sizeKB KB)"
    Get-ChildItem $backupDir -Filter 'cogitia_*.dump' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force
}

function Get-PasswordMismatchHelp {
    $f = $envCfg.secrets_file
    return "The database volume '$($registry.services.database.volume)' was created with a different POSTGRES_PASSWORD than the one in $f " +
           "(PostgreSQL keeps the password it was first created with; use the same $f on every machine).`n" +
           "    Fix, keeping the data:     .\deploy-local.ps1 -SyncDbPassword`n" +
           "    Or restore the previous POSTGRES_PASSWORD in $f`n" +
           "    Or reset to the seed data: .\clean-all-local.ps1 -PurgeData ; .\deploy-local.ps1"
}

function Invoke-DbShell {
    <#
        Runs a sh command with $InputText on stdin (keeps secrets off command lines), either
        inside the database container (-Exec) or in a throwaway container on NetCogitia.
    #>
    param([string]$InputText, [string]$Command, [string[]]$ShArgs, [switch]$Exec)
    $target = if ($Exec) { @('exec', '-i', $registry.services.database.container_name) }
              else { @('run', '--rm', '-i', '--network', $registry.network_name, '--entrypoint', 'sh', "$($registry.services.database.image_name):$($registry.image_tag)") }
    $shell = if ($Exec) { @('sh', '-c', $Command) } else { @('-c', $Command) }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $InputText | & docker @target @shell @ShArgs 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
    } finally { $ErrorActionPreference = $previous }
}

function Test-LocalDbPassword {
    <#
        True when POSTGRES_PASSWORD authenticates over NetCogitia, exactly like the Back-End.
        (Inside the database container 127.0.0.1 is trusted, so a check there proves nothing.)
        PowerShell pipes a CRLF to native stdin: the CR is stripped before use.
    #>
    $r = Invoke-DbShell $secrets['POSTGRES_PASSWORD'] 'PGPASSWORD=$(head -n 1 | tr -d \\r) && export PGPASSWORD && exec psql -h $0 -U $1 -d $2 -f /dev/null' `
        @($registry.services.database.alias, $registry.database.user, $registry.database.name)
    return $r.ExitCode -eq 0
}

function Sync-LocalDbPassword {
    $db = $registry.services.database
    Write-CogitiaStep "Setting the $($db.container_name) password from $($envCfg.secrets_file) (data kept)"
    Invoke-LocalCompose @('up', '-d', 'database')
    Wait-CogitiaHealthy -Containers @($db.container_name) -TimeoutSec $HealthTimeoutSec
    # Local socket connections are trusted inside the container: no old password needed.
    $sql = "ALTER USER `"$($registry.database.user)`" WITH PASSWORD '$($secrets['POSTGRES_PASSWORD'])';"
    $r = Invoke-DbShell $sql 'exec psql -v ON_ERROR_STOP=1 -q -U $0 -d $1' @($registry.database.user, $registry.database.name) -Exec
    if ($r.ExitCode -ne 0) { throw "ALTER USER failed: $($r.Output -join ' ')" }
    if (-not (Test-LocalDbPassword)) { throw "Password still rejected after ALTER USER" }
    Write-CogitiaOk "Database password aligned with $($envCfg.secrets_file)"
}

$exitCode = 0
$overallStart = Get-Date
try {
    Write-CogitiaBanner 'Terra-Cogitia -- Local Deployment (Docker Desktop)'

    # --- Phase 1: Prerequisites ------------------------------------------------
    Write-CogitiaPhase 'PHASE 1: Prerequisites'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    Set-CogitiaActiveEnvironment $registry 'local'
    $envCfg = Get-CogitiaEnvironment $registry 'local'
    $docker = Assert-CogitiaDocker -RequireBuildx:(-not $SkipBuild)
    Write-CogitiaOk "Docker engine $($docker.Engine), compose $($docker.Compose)"
    Assert-CogitiaSources $registry
    Write-CogitiaOk 'Sources, Dockerfiles and compose file present'

    $secretsPath = Resolve-CogitiaPath $registry $envCfg.secrets_file
    # The password is set ONCE by you, in one secrets.local.env that you copy to every machine
    # (it is git-ignored, so it never comes with a clone). Never generated: a per-machine random
    # password is exactly what made machines disagree.
    if (-not (Test-Path $secretsPath)) {
        throw "$($envCfg.secrets_file) not found in $(Split-Path -Parent $secretsPath).`n" +
              "    Copy it from a machine where Terra-Cogitia already runs (same POSTGRES_PASSWORD everywhere),`n" +
              "    or, the very first time, create it:  Copy-Item secrets.env.example $($envCfg.secrets_file)  and set POSTGRES_PASSWORD."
    }
    $secrets = Read-CogitiaSecrets $secretsPath -Required @('POSTGRES_PASSWORD') -Optional @('MISTRAL_API_KEY', 'MISTRAL_MODEL', 'OPENAI_API_KEY', 'MODELS_API_TOKEN', 'AUTH_SECRET', 'PEXELS_API_KEY', 'OPENVERSE_TOKEN')
    if (-not $secrets['MISTRAL_API_KEY']) {
        Write-CogitiaWarn "MISTRAL_API_KEY empty in $($envCfg.secrets_file): the stack runs, AI generation endpoints will fail"
    }
    Write-CogitiaOk "Secrets loaded from $($envCfg.secrets_file)"

    $services   = @(Get-CogitiaServices $registry)
    $containers = @($services | ForEach-Object { $_.Container })
    $runtimeDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.runtime_dir) 'local'
    $composeFile = Join-Path (Resolve-CogitiaPath $registry $registry.paths.docker_dir) 'docker-compose.yml'

    Write-Host ""
    Write-Host "  Containers: $($containers -join ', ')" -ForegroundColor Cyan
    Write-Host "  Network:    $($registry.network_name)" -ForegroundColor Cyan
    Write-Host "  Front-End:  $($envCfg.frontend_url)   Back-End: $($envCfg.api_base_url)" -ForegroundColor Cyan

    # --- Phase 2: Build ----------------------------------------------------------
    Write-CogitiaPhase 'PHASE 2: Build images'
    if ($SkipBuild) {
        Assert-CogitiaImagesExist $registry
        Write-CogitiaInfo 'SKIPPED (-SkipBuild): existing images found'
    } else {
        Build-CogitiaImages $registry -NoCache:$NoCache | Out-Null
    }

    # --- Phase 3: Runtime configuration ---------------------------------------
    Write-CogitiaPhase 'PHASE 3: Runtime configuration'
    $files = New-CogitiaRuntimeFiles -Registry $registry -EnvironmentName 'local' -OutDir $runtimeDir -Secrets $secrets
    Write-CogitiaOk "Generated $($files.Env)"
    Write-CogitiaOk "Generated $(Split-Path -Parent $files.Backend)\*.env"

    # --- Phase 4: Deploy ---------------------------------------------------------
    Write-CogitiaPhase 'PHASE 4: Deploy'
    if ($SkipBackup) { Write-CogitiaInfo 'Database backup SKIPPED (-SkipBackup)' } else { Backup-LocalDatabase }

    if ($null -eq (Get-CogitiaNetworkMembers $registry.network_name)) {
        Invoke-CogitiaNative docker @('network', 'create', '--label', $registry.image_label, $registry.network_name) -Quiet | Out-Null
        Write-CogitiaOk "Network $($registry.network_name) created"
    } else {
        Write-CogitiaOk "Network $($registry.network_name) already exists"
    }

    # Containers with our names but not owned by the compose project would block 'up' (name conflict).
    foreach ($c in $containers) {
        $owner = Invoke-CogitiaNative docker @('container', 'inspect', '-f', '{{json .Config.Labels}}', $c) -AllowFailure -Quiet
        if ($owner.ExitCode -ne 0) { continue }
        $labels = ($owner.Output -join '') | ConvertFrom-Json
        $project = if ($labels -and $labels.PSObject.Properties['com.docker.compose.project']) { $labels.'com.docker.compose.project' } else { '' }
        if ($project -ne $registry.compose_project) {
            Write-CogitiaWarn "Removing stray container $c (not managed by compose project '$($registry.compose_project)')"
            Invoke-CogitiaNative docker @('rm', '-f', $c) -Quiet | Out-Null
        }
    }

    if ($SyncDbPassword) {
        Sync-LocalDbPassword
    } elseif ((Get-CogitiaContainerState $registry.services.database.container_name) -eq 'running/healthy') {
        if (-not (Test-LocalDbPassword)) { throw (Get-PasswordMismatchHelp) }
        Write-CogitiaOk "Database accepts POSTGRES_PASSWORD from $($envCfg.secrets_file)"
    }

    Write-CogitiaStep 'docker compose up -d (recreates containers whose image or configuration changed)'
    Invoke-LocalCompose @('up', '-d', '--remove-orphans')

    # --- Phase 5: Health ---------------------------------------------------------
    Write-CogitiaPhase 'PHASE 5: Health'
    try {
        Wait-CogitiaHealthy -Containers $containers -TimeoutSec $HealthTimeoutSec -FatalLogPattern 'password authentication failed'
    } catch {
        $beLogs = (Invoke-CogitiaNative docker @('logs', '--tail', '100', $registry.services.backend.container_name) -AllowFailure -Quiet).Output -join "`n"
        if ($beLogs -match 'password authentication failed') { throw (Get-PasswordMismatchHelp) }
        throw
    }

    # --- Phase 6: Verification ---------------------------------------------------
    Write-CogitiaPhase 'PHASE 6: Verification'
    $svc = $registry.services
    $checks = @()
    $checks += Get-CogitiaEndpointChecks -Registry $registry `
        -FrontendBase "http://localhost:$($svc.frontend.port)" -BackendBase "http://localhost:$($svc.backend.port)" `
        -ExpectedApiBaseUrl $envCfg.api_base_url -Origin $envCfg.frontend_url

    $members = Get-CogitiaNetworkMembers $registry.network_name
    if ($null -eq $members) { $members = @() }
    $missing = @($containers | Where-Object { $_ -notin $members })
    $checks += New-CogitiaCheck "All containers on $($registry.network_name)" ($missing.Count -eq 0) $(if ($missing) { "missing: $($missing -join ', ')" } else { $members -join ', ' })

    $net = Invoke-CogitiaNative docker @('exec', $svc.frontend.container_name, 'wget', '-q', '-O', '/dev/null', "http://$($svc.backend.alias):$($svc.backend.container_port)$($svc.backend.health_path)") -AllowFailure -Quiet
    $checks += New-CogitiaCheck 'Front-End -> Back-End via NetCogitia DNS' ($net.ExitCode -eq 0) "http://$($svc.backend.alias):$($svc.backend.container_port)"

    $dbNet = Invoke-CogitiaNative docker @('exec', $svc.backend.container_name, 'python', '-c', "import socket; socket.create_connection(('$($svc.database.alias)', $($svc.database.container_port)), 5)") -AllowFailure -Quiet
    $checks += New-CogitiaCheck 'Back-End -> Database via NetCogitia DNS' ($dbNet.ExitCode -eq 0) "$($svc.database.alias):$($svc.database.container_port)"

    $modelsUrl = "http://$($svc.models.alias):$($svc.models.container_port)$($svc.models.health_path)"
    $modelsNet = Invoke-CogitiaNative docker @('exec', $svc.backend.container_name, 'python', '-c', "import urllib.request; urllib.request.urlopen('$modelsUrl', timeout=10)") -AllowFailure -Quiet
    $checks += New-CogitiaCheck 'Back-End -> Models via NetCogitia DNS' ($modelsNet.ExitCode -eq 0) $modelsUrl

    foreach ($c in $containers) {
        $policy = (Invoke-CogitiaNative docker @('container', 'inspect', '-f', '{{.HostConfig.RestartPolicy.Name}}', $c) -Quiet).Output -join ''
        $checks += New-CogitiaCheck "Restart policy $c" ($policy -eq 'unless-stopped') $policy
    }
    $dbPorts = (Invoke-CogitiaNative docker @('port', $svc.database.container_name) -AllowFailure -Quiet).Output -join ' '
    $checks += New-CogitiaCheck 'Database not published on host' ([string]::IsNullOrWhiteSpace($dbPorts)) $(if ($dbPorts) { $dbPorts } else { 'internal only' })
    $modelsPorts = (Invoke-CogitiaNative docker @('port', $svc.models.container_name) -AllowFailure -Quiet).Output -join ' '
    $checks += New-CogitiaCheck 'Models not published on host' ([string]::IsNullOrWhiteSpace($modelsPorts)) $(if ($modelsPorts) { $modelsPorts } else { 'internal only' })

    if (Test-CogitiaServiceEnabled $registry 'voice') {
        $voiceUrl = "http://$($svc.voice.alias):$($svc.voice.container_port)$($svc.voice.health_path)"
        $voiceNet = Invoke-CogitiaNative docker @('exec', $svc.backend.container_name, 'python', '-c', "import urllib.request; urllib.request.urlopen('$voiceUrl', timeout=10)") -AllowFailure -Quiet
        $checks += New-CogitiaCheck 'Back-End -> Voice via NetCogitia DNS' ($voiceNet.ExitCode -eq 0) $voiceUrl
        $voicePorts = (Invoke-CogitiaNative docker @('port', $svc.voice.container_name) -AllowFailure -Quiet).Output -join ' '
        $checks += New-CogitiaCheck 'Voice not published on host' ([string]::IsNullOrWhiteSpace($voicePorts)) $(if ($voicePorts) { $voicePorts } else { 'internal only' })
    }
    $workerDb = Invoke-CogitiaNative docker @('exec', $svc.worker.container_name, 'python', '-c', "import socket; socket.create_connection(('$($svc.database.alias)', $($svc.database.container_port)), 5)") -AllowFailure -Quiet
    $checks += New-CogitiaCheck 'Worker -> Database via NetCogitia DNS' ($workerDb.ExitCode -eq 0) "$($svc.database.alias):$($svc.database.container_port)"
    $workerFfmpeg = Invoke-CogitiaNative docker @('exec', $svc.worker.container_name, 'ffmpeg', '-hide_banner', '-encoders') -AllowFailure -Quiet
    $checks += New-CogitiaCheck 'Worker ffmpeg (libx264)' (($workerFfmpeg.ExitCode -eq 0) -and (($workerFfmpeg.Output -join ' ') -match 'libx264')) 'media composition'
    $workerPorts = (Invoke-CogitiaNative docker @('port', $svc.worker.container_name) -AllowFailure -Quiet).Output -join ' '
    $checks += New-CogitiaCheck 'Worker not published on host' ([string]::IsNullOrWhiteSpace($workerPorts)) $(if ($workerPorts) { $workerPorts } else { 'internal only' })

    $failures = Write-CogitiaChecks $checks
    if ($failures -gt 0) { throw "$failures verification check(s) failed" }

    # --- Phase 7: Cleanup --------------------------------------------------------
    Write-CogitiaPhase 'PHASE 7: Cleanup (Terra-Cogitia dangling images only)'
    Invoke-CogitiaNative docker @('image', 'prune', '-f', '--filter', "label=$($registry.image_label)") | Out-Null

    Write-CogitiaBanner 'Local Deployment Succeeded'
    Write-Host "  Front-End:  $($envCfg.frontend_url)" -ForegroundColor Green
    Write-Host "  Back-End:   $($envCfg.api_base_url)  (docs: $($envCfg.api_base_url)/docs)" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-CogitiaFail $_.Exception.Message
    Write-Host "  Local deployment FAILED." -ForegroundColor Red
    $exitCode = 1
}
finally {
    Write-Host "  Total time: $([math]::Round(((Get-Date) - $overallStart).TotalMinutes, 1)) min" -ForegroundColor Cyan
    Write-Host ""
}
exit $exitCode
