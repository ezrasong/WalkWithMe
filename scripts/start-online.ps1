# Run a loopback-only KAZE backend behind a temporary Cloudflare HTTPS tunnel.
# Ctrl+C stops only the child processes started by this invocation.
$ErrorActionPreference = 'Stop'
$kazeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$kazeArtifacts = Join-Path $kazeRoot 'artifacts'
$kazeClientDir = Join-Path $env:USERPROFILE '.cache\kaze-cloudflared\2026.10.1'
$kazeClient = Join-Path $kazeClientDir 'cloudflared.exe'
$kazeExpectedHash = '4d2490e74082c5d48dbfedaf92576fa5bd1702379ab88eb7faa0cfbe8dc891b6'
$kazeBackend = $null
$kazeTunnel = $null
$kazePublishedUrl = $false
$kazeUrlFile = Join-Path $kazeArtifacts 'online-url.txt'

try {
    $kazeNode = (Get-Command node -ErrorAction Stop).Source
    if (-not (Test-Path -LiteralPath (Join-Path $kazeRoot 'node_modules'))) {
        throw 'Run npm.cmd install in the repository first.'
    }
    # Refuse to reuse or replace another server, including device-test fixtures.
    $kazeProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 4173)
    try { $kazeProbe.Start() }
    catch { throw 'Port 4173 is occupied. Stop its server before starting online mode.' }
    finally { $kazeProbe.Stop() }

    New-Item -ItemType Directory -Force -Path $kazeArtifacts, $kazeClientDir | Out-Null
    if (-not (Test-Path -LiteralPath $kazeClient)) {
        Write-Output 'Downloading Cloudflare tunnel client 2026.10.1...'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.1/cloudflared-windows-amd64.exe' -OutFile $kazeClient
    }
    if ((Get-FileHash -LiteralPath $kazeClient -Algorithm SHA256).Hash.ToLowerInvariant() -ne $kazeExpectedHash) {
        throw "Cloudflare client checksum mismatch. Remove $kazeClient and retry."
    }

    # Preserve the caller's environment, database and existing app settings.
    $kazePreviousHost = $env:HOST
    $kazePreviousPort = $env:PORT
    $kazePreviousDb = $env:KAZE_DB
    try {
        $env:HOST = '127.0.0.1'
        $env:PORT = '4173'
        $env:KAZE_DB = 'data/kaze.sqlite'
        $kazeBackend = Start-Process -FilePath $kazeNode -ArgumentList 'src/server.js' -WorkingDirectory $kazeRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $kazeArtifacts 'online-backend.stdout.log') -RedirectStandardError (Join-Path $kazeArtifacts 'online-backend.stderr.log')
    } finally {
        $env:HOST = $kazePreviousHost
        $env:PORT = $kazePreviousPort
        $env:KAZE_DB = $kazePreviousDb
    }
    $kazeReady = $false
    for ($kazeAttempt = 0; $kazeAttempt -lt 20; $kazeAttempt++) {
        if ($kazeBackend.HasExited) { throw 'Backend exited. See artifacts/online-backend.stderr.log.' }
        try { $kazeReady = (Invoke-RestMethod 'http://127.0.0.1:4173/api/health' -TimeoutSec 2).ok -eq $true } catch {}
        if ($kazeReady) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $kazeReady) { throw 'Backend did not become ready.' }

    $kazeTunnelLog = Join-Path $kazeArtifacts 'online-tunnel.stderr.log'
    $kazeTunnel = Start-Process -FilePath $kazeClient -ArgumentList 'tunnel', '--no-autoupdate', '--protocol', 'http2', '--url', 'http://127.0.0.1:4173' -WorkingDirectory $kazeClientDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $kazeArtifacts 'online-tunnel.stdout.log') -RedirectStandardError $kazeTunnelLog
    $kazePublicUrl = $null
    $kazeReachable = $false
    $kazeUsingDoh = $false
    $kazeCurl = Get-Command curl.exe -ErrorAction SilentlyContinue
    Write-Output 'Connecting the HTTPS tunnel...'
    for ($kazeAttempt = 0; $kazeAttempt -lt 60; $kazeAttempt++) {
        if ($kazeTunnel.HasExited) { throw 'Tunnel exited. See artifacts/online-tunnel.stderr.log.' }
        $kazeText = Get-Content -LiteralPath $kazeTunnelLog -Raw -ErrorAction SilentlyContinue
        if ($kazeText -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $kazePublicUrl = $Matches[0] }
        if ($kazePublicUrl) {
            try { $kazeReachable = (Invoke-RestMethod "$kazePublicUrl/api/health" -TimeoutSec 3).ok -eq $true } catch {}
            # Some local resolvers cache NXDOMAIN for a newly created hostname.
            # Verify through HTTPS DNS without changing the computer's DNS settings.
            if (-not $kazeReachable -and $kazeCurl) {
                try {
                    $kazeHealth = & $kazeCurl.Source --doh-url https://cloudflare-dns.com/dns-query --silent --fail --max-time 5 "$kazePublicUrl/api/health"
                    if ($LASTEXITCODE -eq 0 -and ($kazeHealth | ConvertFrom-Json).ok -eq $true) {
                        $kazeReachable = $true
                        $kazeUsingDoh = $true
                    }
                } catch {}
            }
            if ($kazeReachable) { break }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $kazeReachable) { throw 'Public HTTPS health check failed. See artifacts/online-tunnel.stderr.log.' }
    Set-Content -LiteralPath $kazeUrlFile -Value $kazePublicUrl -Encoding ascii
    $kazePublishedUrl = $true
    Write-Output "KAZE is online: $kazePublicUrl"
    if ($kazeUsingDoh) { Write-Output 'Verified using HTTPS DNS; the PC DNS resolver has not resolved this new hostname yet. Try cellular if this Wi-Fi cannot resolve it.' }
    Write-Output 'Use this server URL in the phone app. Keep this window open and the PC awake.'
    Write-Output 'Ctrl+C stops the backend and tunnel. The URL changes on restart.'
    while (-not $kazeTunnel.WaitForExit(1000)) {
        if ($kazeBackend.HasExited) { throw 'Backend exited; stopping its tunnel.' }
    }
    throw 'Tunnel stopped. Restart the script to reconnect with a new address.'
} finally {
    foreach ($kazeChild in @($kazeTunnel, $kazeBackend)) {
        if ($null -ne $kazeChild -and -not $kazeChild.HasExited) {
            Stop-Process -Id $kazeChild.Id -ErrorAction SilentlyContinue
            $kazeChild.WaitForExit(5000) | Out-Null
        }
    }
    if ($kazePublishedUrl -and (Test-Path -LiteralPath $kazeUrlFile)) { Remove-Item -LiteralPath $kazeUrlFile }
}
