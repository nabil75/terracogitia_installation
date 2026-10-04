#Requires -Version 5.1
<#
.SYNOPSIS
    Shared functions for the Terra-Cogitia deployment scripts.

.DESCRIPTION
    Logging, registry/secrets loading, runtime-file generation, native command
    execution, Docker helpers, HTTP verification and SSH/SCP session handling
    (password auth via SSH_ASKPASS, same mechanism as PlanningPowerTools, but the
    password is never written to disk).

    Imported by deploy-local.ps1, deploy-all.ps1, clean-all-local.ps1,
    clean-all.ps1 and renew-certificates.ps1.
#>

Set-StrictMode -Version Latest

$script:InstallRoot  = Split-Path -Parent $PSScriptRoot
$script:ServiceOrder = @('database', 'models', 'voice', 'backend', 'worker', 'frontend')

# PowerShell 5.1 defaults to TLS 1.0 for Invoke-WebRequest.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# =============================================================================
# Logging
# =============================================================================

function Write-CogitiaBanner {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}

function Write-CogitiaPhase {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

function Write-CogitiaStep { param([string]$Message) Write-Host "  > $Message" -ForegroundColor White }
function Write-CogitiaInfo { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-CogitiaOk   { param([string]$Message) Write-Host "  [OK]   $Message" -ForegroundColor Green }
function Write-CogitiaWarn { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-CogitiaFail { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# =============================================================================
# Registry
# =============================================================================

function Get-CogitiaValue {
    <# Reads a dotted path ("services.backend.port") from a JSON object; $null when absent. #>
    param($Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Assert-CogitiaSettings {
    param($Object, [string[]]$Paths, [string]$Source)
    $missing = @($Paths | Where-Object {
        $v = Get-CogitiaValue $Object $_
        ($null -eq $v) -or (($v -is [string]) -and [string]::IsNullOrWhiteSpace($v)) -or (($v -is [array]) -and $v.Count -eq 0)
    })
    if ($missing.Count -gt 0) {
        throw "Missing required setting(s) in ${Source}: $($missing -join ', ')"
    }
}

function Get-CogitiaRegistry {
    param([string]$Path = (Join-Path $script:InstallRoot 'cogitia-registry.json'))

    if (-not (Test-Path $Path)) { throw "Registry not found: $Path" }
    try {
        $registry = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Registry '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    $required = @('compose_project', 'network_name', 'image_label', 'image_tag',
                  'paths.docker_dir', 'paths.remote_dir', 'paths.export_dir', 'paths.runtime_dir', 'paths.backup_dir',
                  'database.name', 'database.user')
    foreach ($svc in $script:ServiceOrder) {
        $required += "services.$svc.container_name", "services.$svc.alias", "services.$svc.image_name",
                     "services.$svc.dockerfile", "services.$svc.build_context"
        # The media worker serves no port (it pulls jobs from PostgreSQL).
        if ($svc -ne 'worker') { $required += "services.$svc.container_port" }
    }
    $required += 'services.database.volume', 'services.backend.volume', 'services.models.health_path',
                 'services.voice.health_path', 'services.voice.cpus', 'services.voice.memory',
                 'services.worker.pools', 'services.worker.cpus',
                 'services.backend.port', 'services.backend.health_path', 'services.backend.db_check_path',
                 'services.frontend.port', 'services.frontend.health_path'
    Assert-CogitiaSettings $registry $required "registry '$Path'"

    if ($registry.image_label -notmatch '^[a-z0-9.-]+=[A-Za-z0-9._-]+$') {
        throw "Registry: image_label must look like 'key=value' (got '$($registry.image_label)')"
    }

    $registry | Add-Member -NotePropertyName InstallRoot  -NotePropertyValue $script:InstallRoot -Force
    $registry | Add-Member -NotePropertyName RegistryPath -NotePropertyValue $Path -Force
    return $registry
}

function Resolve-CogitiaPath {
    <# Resolves a registry path (relative to the Installation directory) to an absolute path. #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$RelativePath)
    return [IO.Path]::GetFullPath([IO.Path]::Combine($Registry.InstallRoot, $RelativePath))
}

function Set-CogitiaActiveEnvironment {
    <# Records which environment a script deploys, so optional services follow that environment. #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][ValidateSet('local', 'production')][string]$Name)
    $Registry | Add-Member -NotePropertyName ActiveEnvironment -NotePropertyValue $Name -Force
}

function Test-CogitiaServiceEnabled {
    <#
        Core services are always on. An optional service ("optional": true, e.g. voice) is on only in the
        environments that list it in environments.<env>.optional_services (local: yes, production: no).
    #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$Name, [string]$EnvironmentName)
    if (-not [bool](Get-CogitiaValue $Registry.services.$Name 'optional')) { return $true }
    $envName = if ($EnvironmentName) { $EnvironmentName } else { [string](Get-CogitiaValue $Registry 'ActiveEnvironment') }
    if (-not $envName) { return $false }
    return @(Get-CogitiaValue $Registry "environments.$envName.optional_services") -contains $Name
}

function Get-CogitiaServices {
    <#
        Services in dependency order (database, models, voice, backend, worker, frontend) with resolved paths.
        Disabled optional services are left out (not built, exported or waited for) unless -All (clean-up).
    #>
    param([Parameter(Mandatory)]$Registry, [switch]$All)
    foreach ($name in $script:ServiceOrder) {
        if (-not $All -and -not (Test-CogitiaServiceEnabled $Registry $name)) { continue }
        $svc = $Registry.services.$name
        [pscustomobject]@{
            Name          = $name
            Container     = $svc.container_name
            Alias         = $svc.alias
            Image         = "$($svc.image_name):$($Registry.image_tag)"
            ImageName     = $svc.image_name
            Dockerfile    = Resolve-CogitiaPath $Registry $svc.dockerfile
            Context       = Resolve-CogitiaPath $Registry $svc.build_context
            Target        = [string](Get-CogitiaValue $svc 'build_target')
            RequiredFiles = @(Get-CogitiaValue $svc 'required_files' | Where-Object { $_ })
        }
    }
}

function Get-CogitiaEnvironment {
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][ValidateSet('local', 'production')][string]$Name)

    $envCfg = Get-CogitiaValue $Registry "environments.$Name"
    if ($null -eq $envCfg) { throw "Registry: environments.$Name is missing" }

    $required = @('secrets_file', 'bind_address', 'frontend_url', 'api_base_url', 'cors_origins')
    if ($Name -eq 'production') {
        $required += 'server.host', 'server.user', 'server.deploy_dir', 'domains.app', 'domains.api', 'certificate.cert_name'
    }
    Assert-CogitiaSettings $envCfg $required "registry environments.$Name"

    if ($Name -eq 'production') {
        if ($envCfg.server.deploy_dir -notmatch '^/[A-Za-z0-9._/-]+$' -or $envCfg.server.deploy_dir -eq '/') {
            throw "Registry: server.deploy_dir must be an absolute, non-root Unix path (got '$($envCfg.server.deploy_dir)')"
        }
    }
    if ($envCfg.bind_address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw "Registry: environments.$Name.bind_address must be an IPv4 address (got '$($envCfg.bind_address)')"
    }
    return $envCfg
}

# =============================================================================
# Secrets
# =============================================================================

function Read-CogitiaSecrets {
    <# Parses a KEY=value secrets file and validates required keys. Returns a hashtable. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Required = @(),
        [string[]]$Optional = @()
    )

    $example = Join-Path $script:InstallRoot 'secrets.env.example'
    if (-not (Test-Path $Path)) {
        throw "Secrets file not found: $Path`n    Copy '$example' to '$(Split-Path -Leaf $Path)' and fill in: $($Required -join ', ')"
    }

    $secrets = @{}
    $lineNo = 0
    foreach ($raw in Get-Content $Path -Encoding UTF8) {
        $lineNo++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            throw "${Path}:${lineNo}: expected KEY=value"
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($value.Contains("'")) { throw "${Path}:${lineNo}: single quotes are not allowed in values ($key)" }
        if ($key -notin ($Required + $Optional)) {
            Write-CogitiaWarn "Unknown key '$key' in $(Split-Path -Leaf $Path) (ignored)"
            continue
        }
        $secrets[$key] = $value
    }

    $missing = @($Required | Where-Object { -not $secrets.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($secrets[$_]) })
    if ($missing.Count -gt 0) {
        throw "Required secret(s) missing or empty in ${Path}: $($missing -join ', ')"
    }
    return $secrets
}

function New-CogitiaPassword {
    param([int]$Length = 32)
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# =============================================================================
# Runtime files (cogitia.env + secrets/*.env), consumed by docker-compose.yml
# =============================================================================

function Write-CogitiaLfFile {
    <# Writes UTF-8 (no BOM) with LF line endings -- required for files read by bash/compose on Linux. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

function ConvertTo-CogitiaEnvLines {
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values)
    foreach ($key in $Values.Keys) {
        $value = [string]$Values[$key]
        if ($value -match "['`r`n]") { throw "Value of $key contains a quote or line break" }
        "$key='$value'"
    }
}

function Get-CogitiaRuntimeSettings {
    <# Non-secret settings (cogitia.env). Safe to copy anywhere; also sourced by cogitia-remote.sh. #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$EnvironmentName)

    $envCfg = Get-CogitiaEnvironment $Registry $EnvironmentName
    $svc = $Registry.services
    $tag = $Registry.image_tag
    $values = [ordered]@{
        COMPOSE_PROJECT_NAME = $Registry.compose_project
        COGITIA_ENVIRONMENT  = $EnvironmentName
        NETWORK_NAME         = $Registry.network_name
        IMAGE_LABEL          = $Registry.image_label
        DATABASE_IMAGE       = "$($svc.database.image_name):$tag"
        DATABASE_CONTAINER   = $svc.database.container_name
        DATABASE_ALIAS       = $svc.database.alias
        DATABASE_VOLUME      = $svc.database.volume
        MODELS_IMAGE         = "$($svc.models.image_name):$tag"
        MODELS_CONTAINER     = $svc.models.container_name
        MODELS_ALIAS         = $svc.models.alias
        MODELS_PORT          = $svc.models.container_port
        MODELS_HEALTH_PATH   = $svc.models.health_path
        VOICE_ENABLED        = $(if (Test-CogitiaServiceEnabled $Registry 'voice' $EnvironmentName) { '1' } else { '0' })
        VOICE_IMAGE          = "$($svc.voice.image_name):$tag"
        VOICE_CONTAINER      = $svc.voice.container_name
        VOICE_ALIAS          = $svc.voice.alias
        VOICE_PORT           = $svc.voice.container_port
        VOICE_HEALTH_PATH    = $svc.voice.health_path
        VOICE_CPUS           = $svc.voice.cpus
        VOICE_MEMORY         = $svc.voice.memory
        # Compose starts the optional "voice" service only when its profile is active.
        COMPOSE_PROFILES     = $(if (Test-CogitiaServiceEnabled $Registry 'voice' $EnvironmentName) { 'voice' } else { '' })
        BACKEND_IMAGE        = "$($svc.backend.image_name):$tag"
        BACKEND_CONTAINER    = $svc.backend.container_name
        BACKEND_ALIAS        = $svc.backend.alias
        BACKEND_VOLUME       = $svc.backend.volume
        BACKEND_PORT         = $svc.backend.port
        BACKEND_HEALTH_PATH  = $svc.backend.health_path
        BACKEND_DB_CHECK_PATH = $svc.backend.db_check_path
        WORKER_IMAGE         = "$($svc.worker.image_name):$tag"
        WORKER_CONTAINER     = $svc.worker.container_name
        WORKER_ALIAS         = $svc.worker.alias
        WORKER_POOLS         = $svc.worker.pools
        WORKER_CPUS          = $svc.worker.cpus
        FRONTEND_IMAGE       = "$($svc.frontend.image_name):$tag"
        FRONTEND_CONTAINER   = $svc.frontend.container_name
        FRONTEND_ALIAS       = $svc.frontend.alias
        FRONTEND_PORT        = $svc.frontend.port
        FRONTEND_HEALTH_PATH = $svc.frontend.health_path
        POSTGRES_DB          = $Registry.database.name
        POSTGRES_USER        = $Registry.database.user
        BIND_ADDRESS         = $envCfg.bind_address
        API_BASE_URL         = $envCfg.api_base_url.TrimEnd('/')
        CORS_ORIGINS         = (@($envCfg.cors_origins) -join ',')
        APP_DOMAIN           = [string](Get-CogitiaValue $envCfg 'domains.app')
        API_DOMAIN           = [string](Get-CogitiaValue $envCfg 'domains.api')
        CERT_NAME            = [string](Get-CogitiaValue $envCfg 'certificate.cert_name')
    }
    return $values
}

function New-CogitiaRuntimeFiles {
    <#
        Writes <OutDir>/cogitia.env and, when -Secrets is given, <OutDir>/secrets/database.env,
        <OutDir>/secrets/backend.env, <OutDir>/secrets/models.env and <OutDir>/secrets/voice.env.
        Returns the paths written.
    #>
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$OutDir,
        [hashtable]$Secrets
    )

    $envPath = Join-Path $OutDir 'cogitia.env'
    $settings = Get-CogitiaRuntimeSettings $Registry $EnvironmentName
    Write-CogitiaLfFile $envPath (@("# Generated from cogitia-registry.json by the Installation scripts -- do not edit.") + @(ConvertTo-CogitiaEnvLines $settings))
    $result = [ordered]@{ Env = $envPath }

    if ($Secrets) {
        $dbValues = [ordered]@{ POSTGRES_PASSWORD = $Secrets['POSTGRES_PASSWORD'] }
        $beValues = [ordered]@{ DB_PASSWORD = $Secrets['POSTGRES_PASSWORD'] }
        foreach ($k in @('MISTRAL_API_KEY', 'MISTRAL_MODEL', 'OPENAI_API_KEY', 'MODELS_API_TOKEN', 'AUTH_SECRET', 'PEXELS_API_KEY', 'OPENVERSE_TOKEN')) {
            if ($Secrets.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($Secrets[$k])) { $beValues[$k] = $Secrets[$k] }
        }
        # Optional shared token between Back-End and Cogitia-Models (defence in depth on NetCogitia).
        $modelsValues = [ordered]@{}
        if ($Secrets.ContainsKey('MODELS_API_TOKEN') -and -not [string]::IsNullOrWhiteSpace($Secrets['MODELS_API_TOKEN'])) {
            $modelsValues['MODELS_API_TOKEN'] = $Secrets['MODELS_API_TOKEN']
        }
        $result.Database = Join-Path $OutDir 'secrets\database.env'
        $result.Backend  = Join-Path $OutDir 'secrets\backend.env'
        $result.Models   = Join-Path $OutDir 'secrets\models.env'
        $result.Voice    = Join-Path $OutDir 'secrets\voice.env'
        Write-CogitiaLfFile $result.Database @(ConvertTo-CogitiaEnvLines $dbValues)
        Write-CogitiaLfFile $result.Backend  @(ConvertTo-CogitiaEnvLines $beValues)
        Write-CogitiaLfFile $result.Models   (@('# Cogitia-Models secrets (may be empty)') + @(ConvertTo-CogitiaEnvLines $modelsValues))
        # Cogitia-Voice shares the Models token (same defence in depth); written even when the service is off.
        Write-CogitiaLfFile $result.Voice    (@('# Cogitia-Voice secrets (may be empty)') + @(ConvertTo-CogitiaEnvLines $modelsValues))
    }
    return [pscustomobject]$result
}

# =============================================================================
# Native command execution
# =============================================================================

function Invoke-CogitiaNative {
    <#
        Runs a native executable, streams its output (unless -Quiet), and throws on a
        non-zero exit code (unless -AllowFailure). Returns { ExitCode, Output }.
        stderr is merged; PowerShell 5.1 would otherwise turn it into terminating errors.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure,
        [switch]$Quiet,
        [string]$Indent = '    ',
        [string]$DisplayName
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            $lines.Add($line)
            if (-not $Quiet) { Write-Host "$Indent$line" -ForegroundColor DarkGray }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $code) { $code = 0 }

    if ($code -ne 0 -and -not $AllowFailure) {
        $label = if ($DisplayName) { $DisplayName } else { "$FilePath $($ArgumentList -join ' ')" }
        $tail = ($lines | Select-Object -Last 20) -join "`n      "
        throw "$label failed (exit code $code).$(if ($Quiet -and $tail) { "`n      $tail" })"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines.ToArray() }
}

# =============================================================================
# Local Docker helpers
# =============================================================================

function Assert-CogitiaDocker {
    <# Verifies docker CLI, a running engine, compose v2 and (optionally) buildx. Returns the engine version. #>
    param([switch]$RequireBuildx)

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "docker CLI not found in PATH. Install Docker Desktop."
    }
    $version = Invoke-CogitiaNative docker @('version', '--format', '{{.Server.Version}}') -AllowFailure -Quiet
    if ($version.ExitCode -ne 0 -or -not ($version.Output -join '').Trim()) {
        throw "Docker engine is not reachable. Start Docker Desktop and retry."
    }
    $compose = Invoke-CogitiaNative docker @('compose', 'version', '--short') -AllowFailure -Quiet
    if ($compose.ExitCode -ne 0) { throw "Docker Compose v2 ('docker compose') is not available." }
    if ($RequireBuildx) {
        $buildx = Invoke-CogitiaNative docker @('buildx', 'version') -AllowFailure -Quiet
        if ($buildx.ExitCode -ne 0) { throw "docker buildx is required (named build contexts). Update Docker Desktop." }
    }
    return [pscustomobject]@{ Engine = ($version.Output -join '').Trim(); Compose = ($compose.Output -join '').Trim() }
}

function Assert-CogitiaSources {
    <# Validates that every build context, Dockerfile and required source file exists. #>
    param([Parameter(Mandatory)]$Registry)

    $problems = @()
    $dockerDir = Resolve-CogitiaPath $Registry $Registry.paths.docker_dir
    foreach ($f in @('docker-compose.yml', 'frontend-nginx.conf', 'frontend-env.sh')) {
        if (-not (Test-Path (Join-Path $dockerDir $f))) { $problems += "missing $(Join-Path $dockerDir $f)" }
    }
    foreach ($svc in Get-CogitiaServices $Registry) {
        if (-not (Test-Path $svc.Dockerfile)) { $problems += "[$($svc.Name)] Dockerfile not found: $($svc.Dockerfile)" }
        if (-not (Test-Path $svc.Context))    { $problems += "[$($svc.Name)] build context not found: $($svc.Context)"; continue }
        foreach ($f in $svc.RequiredFiles) {
            if (-not (Test-Path (Join-Path $svc.Context $f))) { $problems += "[$($svc.Name)] required file missing: $(Join-Path $svc.Context $f)" }
        }
    }
    if ($problems.Count -gt 0) { throw "Source validation failed:`n      $($problems -join "`n      ")" }
}

function Build-CogitiaImages {
    param([Parameter(Mandatory)]$Registry, [switch]$NoCache)

    $dockerDir = Resolve-CogitiaPath $Registry $Registry.paths.docker_dir
    $results = @()
    foreach ($svc in Get-CogitiaServices $Registry) {
        Write-CogitiaStep "Building $($svc.Image)  ($($svc.Name))"
        Write-CogitiaInfo "context: $($svc.Context)"
        $start = Get-Date
        $buildArgs = @('build',
                       '-t', $svc.Image,
                       '-f', $svc.Dockerfile,
                       '--build-context', "installation=$dockerDir",
                       '--label', $Registry.image_label,
                       '--label', "com.terra-cogitia.component=$($svc.Name)",
                       '--progress', 'plain')
        if ($svc.Target) { $buildArgs += '--target', $svc.Target }
        if ($NoCache) { $buildArgs += '--no-cache' }
        $buildArgs += $svc.Context
        Invoke-CogitiaNative docker $buildArgs -DisplayName "docker build ($($svc.Name))" | Out-Null
        $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        Write-CogitiaOk "$($svc.Image) built in ${elapsed}s"
        $results += [pscustomobject]@{ Service = $svc.Name; Image = $svc.Image; Seconds = $elapsed }
    }
    return $results
}

function Assert-CogitiaImagesExist {
    param([Parameter(Mandatory)]$Registry)
    foreach ($svc in Get-CogitiaServices $Registry) {
        $r = Invoke-CogitiaNative docker @('image', 'inspect', $svc.Image) -AllowFailure -Quiet
        if ($r.ExitCode -ne 0) { throw "Image $($svc.Image) not found locally. Run without -SkipBuild." }
    }
}

function Export-CogitiaImages {
    <# docker save each image to <ExportDir>/<image_name>.tar. Returns { Service, Image, Path, SizeMB, Sha256 }. #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$ExportDir)

    if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
    foreach ($svc in Get-CogitiaServices $Registry) {
        $tar = Join-Path $ExportDir "$($svc.ImageName).tar"
        Write-CogitiaStep "Exporting $($svc.Image) -> $tar"
        if (Test-Path $tar) { Remove-Item $tar -Force }
        Invoke-CogitiaNative docker @('save', '-o', $tar, $svc.Image) -Quiet -DisplayName "docker save $($svc.Image)" | Out-Null
        Get-CogitiaArchiveInfo $svc $tar
    }
}

function Get-CogitiaArchiveInfo {
    param([Parameter(Mandatory)]$Service, [Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Image archive not found: $Path (run without -SkipBuild)" }
    $item = Get-Item $Path
    [pscustomobject]@{
        Service = $Service.Name
        Image   = $Service.Image
        Path    = $item.FullName
        Name    = $item.Name
        SizeMB  = [math]::Round($item.Length / 1MB, 1)
        Sha256  = (Get-FileHash -Algorithm SHA256 -Path $item.FullName).Hash.ToLowerInvariant()
    }
}

function Get-CogitiaContainerState {
    <# Returns "status/health" (e.g. running/healthy) or "missing". #>
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-CogitiaNative docker @('container', 'inspect', '-f', '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $Name) -AllowFailure -Quiet
    if ($r.ExitCode -ne 0) { return 'missing' }
    return ($r.Output -join '').Trim()
}

function Wait-CogitiaHealthy {
    <#
        -FatalLogPattern: fail immediately (instead of waiting for the timeout) when a container
        that is restarting or unhealthy logs this regex. The error message starts with
        "FATAL-LOG <container>:" so callers can recognise it.
    #>
    param([Parameter(Mandatory)][string[]]$Containers, [int]$TimeoutSec = 300, [string]$FatalLogPattern)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastReport = ''
    while ($true) {
        $states = [ordered]@{}
        foreach ($c in $Containers) { $states[$c] = Get-CogitiaContainerState $c }
        $pending = @($states.Keys | Where-Object { $states[$_] -ne 'running/healthy' })
        if ($pending.Count -eq 0) {
            Write-CogitiaOk "All containers healthy: $($Containers -join ', ')"
            return
        }
        if ($FatalLogPattern) {
            foreach ($c in @($pending | Where-Object { $states[$_] -match '^restarting|unhealthy$|^exited' })) {
                $logs = (Invoke-CogitiaNative docker @('logs', '--tail', '60', $c) -AllowFailure -Quiet).Output -join "`n"
                if ($logs -match $FatalLogPattern) { throw "FATAL-LOG ${c}: $($Matches[0])" }
            }
        }
        $report = ($pending | ForEach-Object { "$_=$($states[$_])" }) -join '  '
        if ($report -ne $lastReport) { Write-CogitiaInfo "waiting: $report"; $lastReport = $report }
        if ((Get-Date) -ge $deadline) {
            foreach ($c in $pending) {
                Write-Host "    --- last log lines: $c" -ForegroundColor Yellow
                Invoke-CogitiaNative docker @('logs', '--tail', '40', $c) -AllowFailure -Indent '      ' | Out-Null
            }
            throw "Containers not healthy after ${TimeoutSec}s: $report"
        }
        Start-Sleep -Seconds 5
    }
}

function Get-CogitiaNetworkMembers {
    param([Parameter(Mandatory)][string]$Network)
    $r = Invoke-CogitiaNative docker @('network', 'inspect', '-f', '{{range .Containers}}{{.Name}} {{end}}', $Network) -AllowFailure -Quiet
    if ($r.ExitCode -ne 0) { return $null }
    # Leading comma: keep an empty array (network exists, no members) distinct from $null (no network).
    return ,@((($r.Output -join ' ').Trim() -split '\s+') | Where-Object { $_ })
}

# =============================================================================
# HTTP verification
# =============================================================================

function Invoke-CogitiaHttp {
    <# HTTP request that never throws. Returns { Ok, Status, Content, Headers, Error }. #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 20
    )
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method $Method -Headers $Headers -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        # PowerShell 5.1 returns byte[] for non-text content types (application/javascript, application/json).
        $content = if ($resp.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
        $headers = @{}
        foreach ($k in $resp.Headers.Keys) { $headers[$k.ToLowerInvariant()] = [string]$resp.Headers[$k] }
        return [pscustomobject]@{ Ok = $true; Status = [int]$resp.StatusCode; Content = $content; Headers = $headers; Error = $null }
    } catch {
        $status = $null
        $response = $null
        if ($_.Exception -is [System.Net.WebException]) { $response = $_.Exception.Response }
        if ($response) { $status = [int]$response.StatusCode }
        return [pscustomobject]@{ Ok = $false; Status = $status; Content = $null; Headers = $null; Error = $_.Exception.Message }
    }
}

function Test-CogitiaEndpoint {
    <# One check result: GET must return 2xx and (optionally) contain a substring. Retries while failing. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [string]$Contains,
        [int]$Retries = 3,
        [int]$DelaySec = 5,
        [int]$TimeoutSec = 30
    )
    $detail = ''
    for ($i = 1; $i -le $Retries; $i++) {
        $r = Invoke-CogitiaHttp -Url $Url -TimeoutSec $TimeoutSec
        if ($r.Ok -and (-not $Contains -or $r.Content.Contains($Contains))) {
            return New-CogitiaCheck $Name $true "HTTP $($r.Status)  $Url"
        }
        $detail = if ($r.Ok) { "HTTP $($r.Status) but body lacks '$Contains'  $Url" } else { "$(if ($r.Status) { "HTTP $($r.Status)" } else { $r.Error })  $Url" }
        if ($i -lt $Retries) { Start-Sleep -Seconds $DelaySec }
    }
    return New-CogitiaCheck $Name $false $detail
}

function Test-CogitiaCors {
    <# CORS preflight exactly as a browser on $Origin would send it before calling the API. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Origin)
    $r = Invoke-CogitiaHttp -Url $Url -Method 'OPTIONS' -Headers @{ 'Origin' = $Origin; 'Access-Control-Request-Method' = 'GET' }
    if (-not $r.Ok) { return New-CogitiaCheck $Name $false "preflight failed: $(if ($r.Status) { "HTTP $($r.Status)" } else { $r.Error })" }
    $allowed = $r.Headers['access-control-allow-origin']
    if ($allowed -eq $Origin) { return New-CogitiaCheck $Name $true "Origin $Origin allowed" }
    return New-CogitiaCheck $Name $false "Origin $Origin NOT allowed (Access-Control-Allow-Origin='$allowed')"
}

function New-CogitiaCheck {
    param([string]$Name, [bool]$Ok, [string]$Detail, [switch]$Warning)
    $status = if ($Ok) { 'OK' } elseif ($Warning) { 'WARN' } else { 'FAIL' }
    [pscustomobject]@{ Check = $Name; Status = $status; Detail = $Detail }
}

function Write-CogitiaChecks {
    <# Prints check results and returns the number of FAILs. #>
    param([Parameter(Mandatory)][object[]]$Checks)
    foreach ($c in $Checks) {
        switch ($c.Status) {
            'OK'   { Write-CogitiaOk   ("{0,-44} {1}" -f $c.Check, $c.Detail) }
            'WARN' { Write-CogitiaWarn ("{0,-44} {1}" -f $c.Check, $c.Detail) }
            default { Write-CogitiaFail ("{0,-44} {1}" -f $c.Check, $c.Detail) }
        }
    }
    return @($Checks | Where-Object { $_.Status -eq 'FAIL' }).Count
}

function Get-CogitiaEndpointChecks {
    <#
        Checks shared by local and remote verification, against host-facing URLs:
        Front-End health + SPA + runtime API URL, Back-End OpenAPI + DB-backed endpoint,
        and the CORS preflight the browser performs (the real Front-End -> Back-End path).
    #>
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$FrontendBase,
        [Parameter(Mandatory)][string]$BackendBase,
        [Parameter(Mandatory)][string]$ExpectedApiBaseUrl,
        [Parameter(Mandatory)][string]$Origin,
        [string]$Label = ''
    )
    $fe = $FrontendBase.TrimEnd('/')
    $be = $BackendBase.TrimEnd('/')
    $svc = $Registry.services
    @(
        Test-CogitiaEndpoint "${Label}Front-End health"          "$fe$($svc.frontend.health_path)"
        Test-CogitiaEndpoint "${Label}Front-End SPA (index.html)" "$fe/" -Contains '<app-root>'
        Test-CogitiaEndpoint "${Label}Front-End runtime API URL"  "$fe/assets/env.js" -Contains "apiBaseUrl: `"$($ExpectedApiBaseUrl.TrimEnd('/'))`""
        Test-CogitiaEndpoint "${Label}Back-End OpenAPI"           "$be$($svc.backend.health_path)"
        Test-CogitiaEndpoint "${Label}Back-End + database"        "$be$($svc.backend.db_check_path)" -TimeoutSec 60
        Test-CogitiaCors     "${Label}Browser -> API (CORS)"      "$be$($svc.backend.db_check_path)" $Origin
    )
}

# =============================================================================
# SSH / SCP (Windows OpenSSH, key auth first, password via SSH_ASKPASS fallback)
# =============================================================================

function New-CogitiaSshSession {
    <#
        Opens an SSH "session" object used by Invoke-CogitiaRemote / Send-CogitiaFile.
        1. Tries key-based auth (BatchMode).
        2. Falls back to password auth via SSH_ASKPASS (same mechanism as PlanningPowerTools),
           password taken from $env:COGITIA_SSH_PASSWORD or prompted. The askpass helper
           echoes an environment variable, so the password is never written to disk.
        Always pair with Close-CogitiaSshSession in a finally block.
    #>
    param([Parameter(Mandatory)]$Server)

    $sys32 = Join-Path $env:SystemRoot 'System32\OpenSSH'
    $ssh = Join-Path $sys32 'ssh.exe'
    $scp = Join-Path $sys32 'scp.exe'
    if (-not (Test-Path $ssh)) {
        $cmd = Get-Command ssh -ErrorAction SilentlyContinue
        if (-not $cmd) { throw "OpenSSH client not found. Enable the Windows 'OpenSSH Client' optional feature." }
        $ssh = $cmd.Source
        $scp = (Get-Command scp -ErrorAction Stop).Source
    }

    # Optional server.port (default 22); '-o Port=' works for both ssh and scp.
    $port = Get-CogitiaValue $Server 'port'
    if (-not $port) { $port = 22 }
    $session = [pscustomobject]@{
        Target      = "$($Server.user)@$($Server.host)"
        Ssh         = $ssh
        Scp         = $scp
        Options     = @('-o', "Port=$port", '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15',
                        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=8')
        Mode        = 'key'
        AskPassFile = $null
    }

    Write-CogitiaStep "Connecting to $($session.Target)"
    $probe = Invoke-CogitiaNative $ssh (@('-o', 'BatchMode=yes') + $session.Options + @($session.Target, 'echo cogitia-ssh-ok')) -AllowFailure -Quiet
    if ($probe.ExitCode -eq 0 -and ($probe.Output -contains 'cogitia-ssh-ok')) {
        Write-CogitiaOk "SSH key authentication ($($session.Target))"
        return $session
    }

    $password = $env:COGITIA_SSH_PASSWORD
    if (-not $password) {
        Write-CogitiaInfo "Key authentication unavailable; password required (set COGITIA_SSH_PASSWORD to skip this prompt)."
        $secure = Read-Host "  SSH password for $($session.Target)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $password) { throw "SSH key authentication failed for $($session.Target) and no password was provided." }

    $session.AskPassFile = Join-Path $env:TEMP "cogitia_askpass_$PID.cmd"
    Set-Content -Path $session.AskPassFile -Encoding ASCII -Value "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!COGITIA_ASKPASS_SECRET!"
    $env:COGITIA_ASKPASS_SECRET = $password
    $env:SSH_ASKPASS            = $session.AskPassFile
    $env:SSH_ASKPASS_REQUIRE    = 'force'
    $env:DISPLAY                = 'localhost:0'
    $session.Mode = 'password'
    $session.Options += @('-o', 'BatchMode=no', '-o', 'PreferredAuthentications=password,keyboard-interactive')

    $probe = Invoke-CogitiaNative $ssh ($session.Options + @($session.Target, 'echo cogitia-ssh-ok')) -AllowFailure -Quiet
    if ($probe.ExitCode -ne 0 -or -not ($probe.Output -contains 'cogitia-ssh-ok')) {
        Close-CogitiaSshSession $session
        throw "SSH password authentication failed for $($session.Target): $(($probe.Output | Select-Object -Last 3) -join ' ')"
    }
    Write-CogitiaOk "SSH password authentication ($($session.Target))"
    return $session
}

function Invoke-CogitiaRemote {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Command,
        [switch]$AllowFailure,
        [switch]$Quiet,
        [string]$Indent = '    ',
        [string]$DisplayName
    )
    if ($Command.Contains('"')) { throw "Remote commands must not contain double quotes (PowerShell 5.1 argument quoting): $Command" }
    $label = if ($DisplayName) { $DisplayName } else { "ssh: $Command" }
    return Invoke-CogitiaNative $Session.Ssh ($Session.Options + @($Session.Target, $Command)) -AllowFailure:$AllowFailure -Quiet:$Quiet -Indent $Indent -DisplayName $label
}

function Send-CogitiaFile {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$LocalPath, [Parameter(Mandatory)][string]$RemotePath)
    if (-not (Test-Path $LocalPath)) { throw "File to upload not found: $LocalPath" }
    Invoke-CogitiaNative $Session.Scp ($Session.Options + @('-q', $LocalPath, "$($Session.Target):$RemotePath")) -Quiet -DisplayName "scp $(Split-Path -Leaf $LocalPath)" | Out-Null
}

function Close-CogitiaSshSession {
    param($Session)
    if ($Session -and $Session.AskPassFile -and (Test-Path $Session.AskPassFile)) {
        Remove-Item $Session.AskPassFile -Force -ErrorAction SilentlyContinue
    }
    foreach ($v in @('COGITIA_ASKPASS_SECRET', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'DISPLAY')) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

function Sync-CogitiaRemoteTooling {
    <#
        Uploads the non-secret tooling every remote script needs: cogitia-remote.sh, the nginx
        templates, docker-compose.yml and cogitia.env (generated from the registry). Normalises
        line endings and permissions. Returns the remote script path.
    #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$StagingDir)

    $prod = Get-CogitiaEnvironment $Registry 'production'
    $dir = $prod.server.deploy_dir
    $remoteDir = Resolve-CogitiaPath $Registry $Registry.paths.remote_dir
    $dockerDir = Resolve-CogitiaPath $Registry $Registry.paths.docker_dir

    Invoke-CogitiaRemote $Session "mkdir -p $dir/images $dir/nginx $dir/backups $dir/secrets && chmod 700 $dir/secrets $dir/backups" -Quiet | Out-Null

    $runtime = New-CogitiaRuntimeFiles -Registry $Registry -EnvironmentName 'production' -OutDir $StagingDir
    $uploads = @(
        @{ Local = (Join-Path $remoteDir 'cogitia-remote.sh');                     Remote = "$dir/cogitia-remote.sh" }
        @{ Local = (Join-Path $remoteDir 'nginx\terra-cogitia-http.conf.template');  Remote = "$dir/nginx/terra-cogitia-http.conf.template" }
        @{ Local = (Join-Path $remoteDir 'nginx\terra-cogitia-https.conf.template'); Remote = "$dir/nginx/terra-cogitia-https.conf.template" }
        @{ Local = (Join-Path $dockerDir 'docker-compose.yml');                    Remote = "$dir/docker-compose.yml" }
        @{ Local = $runtime.Env;                                                   Remote = "$dir/cogitia.env" }
    )
    foreach ($u in $uploads) {
        Send-CogitiaFile $Session $u.Local $u.Remote
        Write-CogitiaInfo "uploaded $($u.Remote)"
    }
    $files = ($uploads | ForEach-Object { $_.Remote }) -join ' '
    Invoke-CogitiaRemote $Session "sed -i 's/\r`$//' $files && chmod 755 $dir/cogitia-remote.sh && chmod 644 $dir/cogitia.env $dir/docker-compose.yml" -Quiet | Out-Null
    return "$dir/cogitia-remote.sh"
}

Export-ModuleMember -Function *-Cogitia*
