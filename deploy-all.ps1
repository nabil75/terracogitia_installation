<#
.SYNOPSIS
    Full Terra-Cogitia deployment to the Hetzner server (build -> export -> transfer -> deploy -> verify).

.DESCRIPTION
    Same pipeline as the PlanningPowerTools deploy-all.ps1, scoped to Terra-Cogitia and
    stopping at the first failed phase:
      Phase 1: Validation   registry, secrets.prod.env, local Docker, sources, SSH, server prerequisites
      Phase 2: Build        docker build + docker save -> exports\*.tar (SHA-256 recorded)
      Phase 3: Transfer     tooling + cogitia.env + secrets (chmod 600) + image archives
                            (SHA-256 verified; archives already on the server are not re-sent)
      Phase 4: Deploy       cogitia-remote.sh deploy: DB backup, NetCogitia, docker load,
                            compose up, health wait, in-server verification, scoped image prune
      Phase 5: nginx        host vhost for app./api. domains (HTTP until a certificate exists)
      Phase 6: Verify       from this machine: direct ports 8200/8201 and public URLs

    Remote layout: <deploy_dir> (default /root/cogitia) -- nothing outside it is modified,
    except the single nginx vhost file terra-cogitia.conf.

.PARAMETER SkipBuild
    Reuse the archives already in exports\ (Phase 2 skipped).

.PARAMETER SkipTransfer
    Do not upload image archives (images already loaded on the server). Tooling,
    configuration and secrets are always synchronised.

.PARAMETER SkipDeploy
    Build and transfer only (Phases 4-6 skipped).

.PARAMETER SkipNginx
    Do not install/refresh the host nginx vhost.

.PARAMETER NoCache
    Pass --no-cache to docker build.

.PARAMETER CleanTar
    Delete the image archives on the server after they are loaded (saves disk; the next
    deployment re-uploads them).

.PARAMETER RegistryPath
    Alternative registry file (default: cogitia-registry.json next to this script).

.EXAMPLE
    .\deploy-all.ps1
    .\deploy-all.ps1 -NoCache
    .\deploy-all.ps1 -SkipBuild                 # redeploy the existing exports
    .\deploy-all.ps1 -SkipBuild -SkipTransfer   # re-apply configuration/secrets only
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipTransfer,
    [switch]$SkipDeploy,
    [switch]$SkipNginx,
    [switch]$NoCache,
    [switch]$CleanTar,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

function Show-Phase {
    param([string]$Label, [bool]$Skipped)
    $tag = if ($Skipped) { 'SKIP' } else { 'RUN ' }
    Write-Host "    [$tag] $Label" -ForegroundColor $(if ($Skipped) { 'DarkGray' } else { 'Green' })
}

function Send-VerifiedArchive {
    param($Session, $Archive, [string]$RemoteDir)
    $remote = "$RemoteDir/$($Archive.Name)"
    $existing = ((Invoke-CogitiaRemote $Session "sha256sum $remote 2>/dev/null | cut -d' ' -f1" -AllowFailure -Quiet).Output -join '').Trim()
    if ($existing -eq $Archive.Sha256) {
        Write-CogitiaOk "$($Archive.Name) already on server (SHA-256 match) -- not re-sent"
        return
    }
    Write-CogitiaStep "Uploading $($Archive.Name) ($($Archive.SizeMB) MB)"
    $start = Get-Date
    Send-CogitiaFile $Session $Archive.Path "$remote.part"
    $uploaded = ((Invoke-CogitiaRemote $Session "sha256sum $remote.part | cut -d' ' -f1" -Quiet).Output -join '').Trim()
    if ($uploaded -ne $Archive.Sha256) {
        Invoke-CogitiaRemote $Session "rm -f $remote.part" -AllowFailure -Quiet | Out-Null
        throw "SHA-256 mismatch after upload of $($Archive.Name) (local $($Archive.Sha256), remote $uploaded)"
    }
    Invoke-CogitiaRemote $Session "mv -f $remote.part $remote" -Quiet | Out-Null
    $secs = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    Write-CogitiaOk "$($Archive.Name) transferred and verified in ${secs}s"
}

function Test-ResolvesTo {
    param([string]$HostName, [string]$ExpectedIp)
    try {
        $ips = @([Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.IPAddressToString })
        return [pscustomobject]@{ Ok = ($ips -contains $ExpectedIp); Ips = ($ips -join ', ') }
    } catch {
        return [pscustomobject]@{ Ok = $false; Ips = 'unresolved' }
    }
}

$exitCode = 0
$session = $null
$stagingDir = $null
$overallStart = Get-Date
try {
    Write-CogitiaBanner 'Terra-Cogitia -- Deployment to Hetzner'

    # --- Phase 1: Validation -----------------------------------------------------
    Write-CogitiaPhase 'PHASE 1: Validation'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    $prod = Get-CogitiaEnvironment $registry 'production'
    $server = $prod.server
    $deployDir = $server.deploy_dir
    $secrets = Read-CogitiaSecrets (Resolve-CogitiaPath $registry $prod.secrets_file) `
        -Required @('POSTGRES_PASSWORD', 'MISTRAL_API_KEY') -Optional @('MISTRAL_MODEL', 'OPENAI_API_KEY')
    Write-CogitiaOk "Secrets loaded from $($prod.secrets_file)"

    $services = @(Get-CogitiaServices $registry)
    $exportDir = Resolve-CogitiaPath $registry $registry.paths.export_dir
    $stagingDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.runtime_dir) 'production'

    if (-not $SkipBuild) {
        $docker = Assert-CogitiaDocker -RequireBuildx
        Write-CogitiaOk "Docker engine $($docker.Engine), compose $($docker.Compose)"
        Assert-CogitiaSources $registry
        Write-CogitiaOk 'Sources, Dockerfiles and compose file present'
    } elseif (-not $SkipTransfer) {
        foreach ($svc in $services) { Get-CogitiaArchiveInfo $svc (Join-Path $exportDir "$($svc.ImageName).tar") | Out-Null }
        Write-CogitiaOk "Existing archives found in $exportDir"
    }

    Write-Host ""
    Write-Host "  Server:     $($server.user)@$($server.host):$deployDir" -ForegroundColor Cyan
    Write-Host "  Containers: $(($services | ForEach-Object { $_.Container }) -join ', ')  on $($registry.network_name)" -ForegroundColor Cyan
    Write-Host "  Public:     $($prod.frontend_url)  /  $($prod.api_base_url)" -ForegroundColor Cyan
    Write-Host "  Phases:" -ForegroundColor White
    Show-Phase 'Phase 2: Build and export' $SkipBuild
    Show-Phase 'Phase 3: Transfer image archives (tooling/config/secrets always synced)' $SkipTransfer
    Show-Phase 'Phase 4: Remote deploy' $SkipDeploy
    Show-Phase 'Phase 5: Host nginx vhost' ($SkipNginx -or $SkipDeploy)
    Show-Phase 'Phase 6: Verification from this machine' $SkipDeploy

    $session = New-CogitiaSshSession $server
    $pre = Invoke-CogitiaRemote $session "docker version --format '{{.Server.Version}}' && docker compose version --short && command -v curl >/dev/null && echo prerequisites-ok" -AllowFailure -Quiet
    if ($pre.ExitCode -ne 0 -or -not ($pre.Output -contains 'prerequisites-ok')) {
        throw "Server prerequisites missing (docker engine, Docker Compose v2 plugin, curl): $($pre.Output -join ' ')"
    }
    $versions = @($pre.Output | Where-Object { $_ -match '^v?\d+\.\d+' })
    Write-CogitiaOk "Server: docker $($versions[0]), compose $($versions[1])"

    # --- Phase 2: Build and export ---------------------------------------------
    Write-CogitiaPhase 'PHASE 2: Build and export'
    if ($SkipBuild) {
        Write-CogitiaInfo 'SKIPPED (-SkipBuild)'
        $archives = if ($SkipTransfer) { @() } else { @($services | ForEach-Object { Get-CogitiaArchiveInfo $_ (Join-Path $exportDir "$($_.ImageName).tar") }) }
    } else {
        Build-CogitiaImages $registry -NoCache:$NoCache | Out-Null
        $archives = @(Export-CogitiaImages $registry $exportDir)
        foreach ($a in $archives) { Write-CogitiaOk "$($a.Name)  $($a.SizeMB) MB  sha256 $($a.Sha256.Substring(0, 12))..." }
    }

    # --- Phase 3: Transfer -------------------------------------------------------
    Write-CogitiaPhase 'PHASE 3: Transfer'
    $remoteScript = Sync-CogitiaRemoteTooling -Session $session -Registry $registry -StagingDir $stagingDir
    Write-CogitiaOk 'Tooling and cogitia.env synchronised'

    $files = New-CogitiaRuntimeFiles -Registry $registry -EnvironmentName 'production' -OutDir $stagingDir -Secrets $secrets
    Send-CogitiaFile $session $files.Database "$deployDir/secrets/database.env"
    Send-CogitiaFile $session $files.Backend  "$deployDir/secrets/backend.env"
    Invoke-CogitiaRemote $session "chmod 700 $deployDir/secrets && chmod 600 $deployDir/secrets/database.env $deployDir/secrets/backend.env" -Quiet | Out-Null
    Remove-Item (Split-Path -Parent $files.Database) -Recurse -Force
    Write-CogitiaOk "Secrets uploaded to $deployDir/secrets (chmod 600; local staging copy deleted)"

    if ($SkipTransfer) {
        Write-CogitiaInfo 'Image archives SKIPPED (-SkipTransfer)'
    } else {
        foreach ($a in $archives) { Send-VerifiedArchive $session $a "$deployDir/images" }
    }

    # --- Phase 4: Remote deploy --------------------------------------------------
    if ($SkipDeploy) {
        Write-CogitiaPhase 'PHASE 4-6: SKIPPED (-SkipDeploy)'
    } else {
        Write-CogitiaPhase 'PHASE 4: Remote deploy'
        $deployCmd = "bash $remoteScript deploy$(if ($CleanTar) { ' --clean-tar' })"
        Write-CogitiaInfo "> $deployCmd"
        Invoke-CogitiaRemote $session $deployCmd -Indent '  ' -DisplayName 'Remote deployment' | Out-Null

        # --- Phase 5: nginx ------------------------------------------------------
        Write-CogitiaPhase 'PHASE 5: Host nginx vhost'
        $nginxSkipped = $false
        if ($SkipNginx) {
            Write-CogitiaInfo 'SKIPPED (-SkipNginx)'
        } else {
            $ng = Invoke-CogitiaRemote $session "bash $remoteScript nginx" -AllowFailure -Indent '  '
            if ($ng.ExitCode -eq 3) { $nginxSkipped = $true; Write-CogitiaWarn 'nginx not installed on the server -- public URLs unavailable' }
            elseif ($ng.ExitCode -ne 0) { throw "nginx vhost installation failed (exit $($ng.ExitCode))" }
        }

        # --- Phase 6: Verification from this machine ---------------------------
        Write-CogitiaPhase 'PHASE 6: Verification from this machine'
        $checks = @()
        $svc = $registry.services
        $directFe = "http://$($server.host):$($svc.frontend.port)"
        $directBe = "http://$($server.host):$($svc.backend.port)"
        if ($prod.bind_address -eq '127.0.0.1') {
            Write-CogitiaInfo 'Direct port checks skipped: ports bound to 127.0.0.1 on the server (reachable via nginx only)'
        } else {
            $origin = if (@($prod.cors_origins) -contains $directFe) { $directFe } else { @($prod.cors_origins)[0] }
            $checks += Get-CogitiaEndpointChecks -Registry $registry -FrontendBase $directFe -BackendBase $directBe `
                -ExpectedApiBaseUrl $prod.api_base_url -Origin $origin -Label 'Direct  '
        }

        if (-not $SkipNginx -and -not $nginxSkipped) {
            $hasCert = ((Invoke-CogitiaRemote $session "test -f /etc/letsencrypt/live/$($prod.certificate.cert_name)/fullchain.pem && echo yes || echo no" -Quiet).Output -join '').Trim() -eq 'yes'
            $scheme = if ($hasCert) { 'https' } else { 'http' }
            if (-not $hasCert) { Write-CogitiaWarn "No certificate yet -- run .\renew-certificates.ps1 -Issue -Email <you@domain> once DNS is in place" }
            $dnsOk = $true
            foreach ($d in @($prod.domains.app, $prod.domains.api)) {
                $dns = Test-ResolvesTo $d $server.host
                if (-not $dns.Ok) {
                    $dnsOk = $false
                    $checks += New-CogitiaCheck "DNS $d" $false "resolves to $($dns.Ips), expected $($server.host) -- create the A record" -Warning
                }
            }
            if ($dnsOk) {
                $checks += Get-CogitiaEndpointChecks -Registry $registry -FrontendBase "${scheme}://$($prod.domains.app)" `
                    -BackendBase "${scheme}://$($prod.domains.api)" -ExpectedApiBaseUrl $prod.api_base_url `
                    -Origin $prod.frontend_url -Label 'Public  '
            }
        }

        $failures = Write-CogitiaChecks $checks
        if ($failures -gt 0) {
            if ($prod.bind_address -ne '127.0.0.1') {
                Write-CogitiaInfo "If only the Direct checks fail: open TCP $($svc.frontend.port)/$($svc.backend.port) in the Hetzner Cloud firewall."
            }
            throw "$failures verification check(s) failed"
        }
    }

    Write-CogitiaBanner 'Deployment to Hetzner Succeeded'
    Write-Host "  Front-End:  $($prod.frontend_url)   (direct http://$($server.host):$($registry.services.frontend.port))" -ForegroundColor Green
    Write-Host "  Back-End:   $($prod.api_base_url)   (direct http://$($server.host):$($registry.services.backend.port))" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-CogitiaFail $_.Exception.Message
    Write-Host "  Deployment FAILED -- see the output above. The previous containers keep running unless Phase 4 had started." -ForegroundColor Red
    $exitCode = 1
}
finally {
    Close-CogitiaSshSession $session
    if ($stagingDir -and (Test-Path (Join-Path $stagingDir 'secrets'))) { Remove-Item (Join-Path $stagingDir 'secrets') -Recurse -Force }
    Write-Host "  Total time: $([math]::Round(((Get-Date) - $overallStart).TotalMinutes, 1)) min" -ForegroundColor Cyan
    Write-Host ""
}
exit $exitCode
