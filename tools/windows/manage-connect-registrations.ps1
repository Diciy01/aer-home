# Owner-side administration only. Never distribute this script or an owner
# token in the client package. No network listeners/system settings are changed.
[CmdletBinding()]
param(
    [ValidateSet('List','Approve','Reject')][string]$Action = 'List',
    [string]$RequestId = '',
    [string]$Fingerprint = '',
    [string]$CoreConfig = 'E:\dev\runs\aer-anywhere-manual-20261029\core.json'
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $CoreConfig -Raw | ConvertFrom-Json
$base = [Uri]("http://" + $cfg.listenAddr + '/api/v1')
if (-not $base.IsLoopback) { throw 'Owner administration requires loopback Core.' }
if ($Action -ne 'List' -and $RequestId -notmatch '^[a-zA-Z0-9_-]{16,80}$') {
    throw 'Specify the exact request ID from List.'
}
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.AllowAutoRedirect = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(20)
try {
    $ownerToken = [IO.File]::ReadAllText((Join-Path $cfg.dataDir 'core.token')).Trim()
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer',$ownerToken)
    $response = $client.GetAsync("$base/remote/registrations").GetAwaiter().GetResult()
    try {
        if (-not $response.IsSuccessStatusCode) { throw "Core returned HTTP $([int]$response.StatusCode)." }
        $envelope = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $requests = @($envelope.data)
    } finally { $response.Dispose() }
    if ($Action -eq 'List') {
        $requests | Select-Object id,name,fingerprint,createdAt,expiresAt | Format-List
        return
    }
    $request = @($requests | Where-Object { $_.id -eq $RequestId })
    if ($request.Count -ne 1) { throw 'No current verified pending request with that ID.' }
    if ($Action -eq 'Approve') {
        $normalized = ($Fingerprint -replace '[:\s-]','').ToLowerInvariant()
        if ($normalized -notmatch '^[0-9a-f]{64}$' -or $normalized -ne $request[0].fingerprint) {
            throw 'Pass the fingerprint of the installation you intend to approve; a name alone is insufficient.'
        }
    }
    $verb = $Action.ToLowerInvariant()
    $content = New-Object System.Net.Http.StringContent('{}',[Text.Encoding]::UTF8,'application/json')
    $response = $client.PostAsync("$base/remote/registrations/$RequestId/$verb",$content).GetAwaiter().GetResult()
    try {
        if (-not $response.IsSuccessStatusCode) { throw "Core returned HTTP $([int]$response.StatusCode). No retry made." }
        Write-Host "Request $RequestId : $Action complete. The client continues automatically."
    } finally { $response.Dispose(); $content.Dispose() }
} finally {
    $ownerToken = $null
    $client.Dispose()
}
