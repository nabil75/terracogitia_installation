<#
.SYNOPSIS
    Push secrets.prod.env changes (API keys) to the running Hetzner deployment -- no build, no transfer.

.DESCRIPTION
    For changing MISTRAL_API_KEY, MISTRAL_MODEL or OPENAI_API_KEY in secrets.prod.env:
      1. Validates secrets.prod.env (same rules as deploy-all.ps1).
      2. Refuses if POSTGRES_PASSWORD differs from the deployed one: it is fixed when the
         database volume is created, so changing it here would lock the Back-End out
         (see README, Troubleshooting, to rotate it).
      3. Uploads secrets/backend.env (chmod 600; local staging copy deleted).
      4. cogitia-remote.sh apply-secrets: recreates Cogitia-BackEnd only (env files are read
         at container creation, a restart is not enough), waits until healthy, runs the
         in-server verification. Front-End, database and data are untouched.

    Downtime: the Back-End only, for the time it takes to start (typically 10-20 s).

.PARAMETER RegistryPath
    Alternative registry file (default: cogitia-registry.json next to this script).

.EXAMPLE
    .\update-secrets.ps1
#>

[CmdletBinding()]
param(
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

$exitCode = 0
$session = $null
$stagingDir = $null
try {
    Write-CogitiaBanner 'Terra-Cogitia -- Update secrets on Hetzner'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    $prod = Get-CogitiaEnvironment $registry 'production'
    $deployDir = $prod.server.deploy_dir
    $secrets = Read-CogitiaSecrets (Resolve-CogitiaPath $registry $prod.secrets_file) `
        -Required @('POSTGRES_PASSWORD', 'MISTRAL_API_KEY') -Optional @('MISTRAL_MODEL', 'OPENAI_API_KEY')
    Write-CogitiaOk "Secrets loaded from $($prod.secrets_file)"

    $stagingDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.runtime_dir) 'production'
    $files = New-CogitiaRuntimeFiles -Registry $registry -EnvironmentName 'production' -OutDir $stagingDir -Secrets $secrets

    $session = New-CogitiaSshSession $prod.server
    $remoteScript = Sync-CogitiaRemoteTooling -Session $session -Registry $registry -StagingDir $stagingDir

    Write-CogitiaPhase 'Checks'
    $remoteDbHash = ((Invoke-CogitiaRemote $session "sha256sum $deployDir/secrets/database.env 2>/dev/null | cut -d' ' -f1" -AllowFailure -Quiet).Output -join '').Trim()
    if (-not $remoteDbHash) {
        throw "No deployed secrets found in $deployDir/secrets -- run .\deploy-all.ps1 first"
    }
    $localDbHash = (Get-FileHash -Algorithm SHA256 $files.Database).Hash.ToLowerInvariant()
    if ($remoteDbHash -ne $localDbHash) {
        throw "POSTGRES_PASSWORD in $($prod.secrets_file) differs from the deployed one. It cannot be changed this way (the database keeps its original password). Restore the previous value, or rotate it as described in README > Troubleshooting."
    }
    Write-CogitiaOk 'POSTGRES_PASSWORD unchanged'

    $remoteBeHash = ((Invoke-CogitiaRemote $session "sha256sum $deployDir/secrets/backend.env 2>/dev/null | cut -d' ' -f1" -AllowFailure -Quiet).Output -join '').Trim()
    if ($remoteBeHash -eq (Get-FileHash -Algorithm SHA256 $files.Backend).Hash.ToLowerInvariant()) {
        Write-CogitiaOk 'Back-End secrets on the server already match secrets.prod.env -- nothing to do'
    } else {
        Write-CogitiaPhase 'Apply'
        Send-CogitiaFile $session $files.Backend "$deployDir/secrets/backend.env"
        Invoke-CogitiaRemote $session "chmod 600 $deployDir/secrets/backend.env" -Quiet | Out-Null
        Write-CogitiaOk "Uploaded $deployDir/secrets/backend.env (chmod 600)"
        Invoke-CogitiaRemote $session "bash $remoteScript apply-secrets" -Indent '  ' -DisplayName 'Apply secrets' | Out-Null
    }

    Write-CogitiaBanner 'Secrets Updated'
}
catch {
    Write-CogitiaFail $_.Exception.Message
    $exitCode = 1
}
finally {
    Close-CogitiaSshSession $session
    if ($stagingDir -and (Test-Path (Join-Path $stagingDir 'secrets'))) { Remove-Item (Join-Path $stagingDir 'secrets') -Recurse -Force }
}
exit $exitCode
