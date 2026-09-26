<#
.SYNOPSIS
    Issue, check and renew the Terra-Cogitia Let's Encrypt certificate on the Hetzner server.

.DESCRIPTION
    Same architecture as PlanningPowerTools: certbot on the host, nginx authenticator
    (http-01 through the host nginx), certificates in /etc/letsencrypt, nginx reload.
    One certificate (cert_name from the registry) covers both app. and api. domains.

    Default mode (check + renew):
      reads `certbot certificates --cert-name <name>`, parses the expiry date and renews
      when fewer than -DaysThreshold days remain (or with -Force). Then refreshes the
      Terra-Cogitia vhost, reloads nginx and verifies the certificate actually served.

    -Issue mode (first time, after DNS A records point at the server):
      requests the certificate (certbot certonly --nginx), switches the vhost to HTTPS,
      reloads nginx and verifies. Idempotent: an existing valid certificate is kept.

    Other certificates managed by certbot on the server are never touched.

.PARAMETER Issue
    Obtain the certificate (first run). Requires -Email.

.PARAMETER Email
    Let's Encrypt account e-mail (expiry notices). Running -Issue accepts the
    Let's Encrypt Subscriber Agreement for that address.

.PARAMETER DaysThreshold
    Renew when fewer than this many days remain. Default 30 (certbot's own window).

.PARAMETER Force
    Force renewal even if not due (mind Let's Encrypt weekly rate limits).

.PARAMETER DryRun
    Use the Let's Encrypt staging server (certbot --dry-run): validates DNS, port 80 and
    nginx plumbing without touching the live certificate.

.PARAMETER RegistryPath
    Alternative registry file (default: cogitia-registry.json next to this script).

.EXAMPLE
    .\renew-certificates.ps1 -Issue -Email admin@terra-cogitia.com -DryRun   # validate first
    .\renew-certificates.ps1 -Issue -Email admin@terra-cogitia.com           # first certificate
    .\renew-certificates.ps1                                                  # check + renew if < 30 days
    .\renew-certificates.ps1 -DryRun                                          # test renewal plumbing
    .\renew-certificates.ps1 -Force                                           # force renewal
#>

[CmdletBinding()]
param(
    [switch]$Issue,
    [string]$Email,
    [ValidateRange(1, 89)][int]$DaysThreshold = 30,
    [switch]$Force,
    [switch]$DryRun,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Cogitia.Common.psm1') -Force -DisableNameChecking

function Get-CertbotState {
    <# Parses `certbot certificates` output (same approach as PlanningPowerTools). Returns $null if absent. #>
    param([string[]]$Lines)
    $cert = $null
    foreach ($raw in $Lines) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*Certificate Name:\s*(\S+)\s*$') {
            $cert = [pscustomobject]@{ Name = $Matches[1]; Domains = @(); ExpiryUtc = $null; DaysLeft = $null }
        } elseif ($cert -and $line -match '^\s*Domains:\s*(.+)$') {
            $cert.Domains = @(($Matches[1] -split '\s+') | Where-Object { $_ })
        } elseif ($cert -and $line -match '^\s*Expiry Date:\s*(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})') {
            # Parse the timestamp ourselves instead of trusting certbot's VALID/EXPIRED label.
            $cert.ExpiryUtc = [DateTime]::ParseExact($Matches[1].Replace('T', ' '), 'yyyy-MM-dd HH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
            $cert.DaysLeft = [math]::Floor(($cert.ExpiryUtc - [DateTime]::UtcNow).TotalDays)
        }
    }
    return $cert
}

function Get-ServedCertificate {
    <# TLS handshake from this machine: returns the certificate nginx actually serves for $HostName. #>
    param([string]$HostName)
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $tcp.Connect($HostName, 443)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        try {
            $ssl.AuthenticateAsClient($HostName)
            $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
            $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
            return [pscustomobject]@{ NotAfter = $cert.NotAfter.ToUniversalTime(); Issuer = $cert.Issuer; ChainValid = $chain.Build($cert); Subject = $cert.Subject }
        } finally { $ssl.Dispose() }
    } finally { $tcp.Dispose() }
}

function Test-ServedCertificates {
    param($Prod, [DateTime]$ExpectedNotAfter)
    $checks = @()
    foreach ($d in @($Prod.domains.app, $Prod.domains.api)) {
        try {
            $served = Get-ServedCertificate $d
            $matchesExpected = ($null -eq $ExpectedNotAfter) -or ([math]::Abs(($served.NotAfter - $ExpectedNotAfter).TotalMinutes) -lt 5)
            $ok = $served.ChainValid -and $matchesExpected
            $checks += New-CogitiaCheck "TLS $d" $ok ("expires $($served.NotAfter.ToString('yyyy-MM-dd'))  chain $(if ($served.ChainValid) { 'valid' } else { 'INVALID' })$(if (-not $matchesExpected) { '  (not the renewed certificate -- nginx not reloaded?)' })")
        } catch {
            $checks += New-CogitiaCheck "TLS $d" $false $_.Exception.Message
        }
    }
    return $checks
}

$exitCode = 0
$session = $null
try {
    Write-CogitiaBanner 'Terra-Cogitia -- Certificates'
    $registry = if ($RegistryPath) { Get-CogitiaRegistry -Path $RegistryPath } else { Get-CogitiaRegistry }
    $prod = Get-CogitiaEnvironment $registry 'production'
    $certName = $prod.certificate.cert_name
    $stagingDir = Join-Path (Resolve-CogitiaPath $registry $registry.paths.runtime_dir) 'production'

    if ($Issue -and $Email -notmatch '^[^\s@''"]+@[^\s@''"]+\.[^\s@''"]+$') { throw "-Issue requires a valid -Email address" }
    if ($Issue -and $Force) { throw "-Force applies to renewal; do not combine it with -Issue" }

    $mode = if ($Issue) { 'ISSUE' } elseif ($Force) { 'FORCE RENEW' } else { 'check + renew' }
    if ($DryRun) { $mode += ' (DRY RUN, staging)' }
    Write-Host "  Server:      $($prod.server.user)@$($prod.server.host)" -ForegroundColor Cyan
    Write-Host "  Certificate: $certName  ->  $($prod.domains.app), $($prod.domains.api)" -ForegroundColor Cyan
    Write-Host "  Mode:        $mode   Threshold: $DaysThreshold days" -ForegroundColor Cyan

    $session = New-CogitiaSshSession $prod.server
    $remoteScript = Sync-CogitiaRemoteTooling -Session $session -Registry $registry -StagingDir $stagingDir
    $tools = Invoke-CogitiaRemote $session 'command -v certbot >/dev/null && command -v nginx >/dev/null && echo tools-ok' -AllowFailure -Quiet
    if (-not ($tools.Output -contains 'tools-ok')) { throw "certbot and nginx must both be installed on the server" }

    Write-CogitiaPhase 'Certificate inventory'
    $state = Get-CertbotState (Invoke-CogitiaRemote $session "bash $remoteScript cert-status" -Quiet).Output
    if ($state -and $state.ExpiryUtc) {
        $color = if ($state.DaysLeft -lt $DaysThreshold) { 'Red' } elseif ($state.DaysLeft -lt 2 * $DaysThreshold) { 'Yellow' } else { 'Green' }
        Write-Host ("    {0,-32} expires {1}  ({2} days)  domains: {3}" -f $state.Name, $state.ExpiryUtc.ToString('yyyy-MM-dd'), $state.DaysLeft, ($state.Domains -join ' ')) -ForegroundColor $color
        $missingDomains = @(@($prod.domains.app, $prod.domains.api) | Where-Object { $_ -notin $state.Domains })
        if ($missingDomains) { Write-CogitiaWarn "Certificate does not cover: $($missingDomains -join ', ') -- re-run with -Issue" }
    } else {
        Write-CogitiaInfo "No certificate named $certName on the server."
    }

    $changed = $false
    if ($Issue) {
        Write-CogitiaPhase 'Issuing'
        foreach ($d in @($prod.domains.app, $prod.domains.api)) {
            try { $ips = @([Net.Dns]::GetHostAddresses($d) | ForEach-Object { $_.IPAddressToString }) } catch { $ips = @() }
            if ($ips -notcontains $prod.server.host) {
                throw "DNS for $d resolves to '$($ips -join ', ')', not $($prod.server.host). Create the A record first (http-01 would fail)."
            }
            Write-CogitiaOk "DNS $d -> $($prod.server.host)"
        }
        # The HTTP vhost must exist so certbot's nginx authenticator finds both server names.
        Invoke-CogitiaRemote $session "bash $remoteScript nginx" -Indent '  ' -DisplayName 'nginx vhost' | Out-Null
        Write-CogitiaInfo 'certbot http-01 challenge running (30-60 s)...'
        Invoke-CogitiaRemote $session "bash $remoteScript cert-issue $Email$(if ($DryRun) { ' --dry-run' })" -Indent '      ' -DisplayName 'certbot certonly' | Out-Null
        $changed = -not $DryRun
    } elseif (-not $state -or -not $state.ExpiryUtc) {
        throw "Certificate $certName does not exist yet. Run: .\renew-certificates.ps1 -Issue -Email <address>"
    } elseif ($Force -or $DryRun -or $state.DaysLeft -lt $DaysThreshold) {
        Write-CogitiaPhase 'Renewing'
        Write-CogitiaInfo 'certbot http-01 challenge running (30-60 s)...'
        $flags = @()
        if ($DryRun) { $flags += '--dry-run' }
        if ($Force -and -not $DryRun) { $flags += '--force' }
        $renew = Invoke-CogitiaRemote $session "bash $remoteScript cert-renew $($flags -join ' ')" -Indent '      ' -AllowFailure
        if ($renew.ExitCode -eq 124) { throw "certbot timed out -- check port 80, DNS and nginx for $certName" }
        if ($renew.ExitCode -ne 0) { throw "certbot renew failed (exit $($renew.ExitCode))" }
        $changed = -not $DryRun
    } else {
        Write-CogitiaOk "$certName is healthy ($($state.DaysLeft) days >= $DaysThreshold) -- no renewal needed"
    }

    Write-CogitiaPhase 'nginx'
    # Switches the vhost to HTTPS as soon as the certificate exists; no-op when unchanged.
    Invoke-CogitiaRemote $session "bash $remoteScript nginx" -Indent '  ' -DisplayName 'nginx vhost' | Out-Null
    if ($changed) {
        $reload = Invoke-CogitiaRemote $session 'nginx -s reload 2>&1 || systemctl reload nginx 2>&1 || rc-service nginx reload 2>&1' -AllowFailure -Quiet
        if ($reload.ExitCode -eq 0) { Write-CogitiaOk 'nginx reloaded' } else { throw "nginx reload failed: $($reload.Output -join ' ')" }
        Start-Sleep -Seconds 2   # reload is asynchronous; verify against the new workers
    }

    Write-CogitiaPhase 'Verification'
    $after = Get-CertbotState (Invoke-CogitiaRemote $session "bash $remoteScript cert-status" -Quiet).Output
    $checks = @()
    if ($after -and $after.ExpiryUtc) {
        $checks += New-CogitiaCheck "certbot $certName" ($after.DaysLeft -ge $DaysThreshold -or $DryRun) "expires $($after.ExpiryUtc.ToString('yyyy-MM-dd')) ($($after.DaysLeft) days)"
        $checks += Test-ServedCertificates $prod $after.ExpiryUtc
        $checks += Test-CogitiaEndpoint 'HTTPS Front-End' "https://$($prod.domains.app)/" -Contains '<app-root>'
        $checks += Test-CogitiaEndpoint 'HTTPS Back-End' "https://$($prod.domains.api)$($registry.services.backend.health_path)"
    } elseif ($DryRun) {
        $checks += New-CogitiaCheck 'Dry run' $true 'staging challenge succeeded; no live certificate yet'
    } else {
        $checks += New-CogitiaCheck "certbot $certName" $false 'certificate not found after operation'
    }
    $failures = Write-CogitiaChecks $checks
    if ($failures -gt 0) { throw "$failures certificate check(s) failed" }

    Write-CogitiaBanner 'Certificates OK'
}
catch {
    Write-CogitiaFail $_.Exception.Message
    Write-Host "  Common fixes: port 80 open, DNS A records -> $($prod.server.host), nginx running, rate limits (use -DryRun)." -ForegroundColor DarkGray
    $exitCode = 1
}
finally {
    Close-CogitiaSshSession $session
}
exit $exitCode
