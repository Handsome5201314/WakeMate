param([string]$PatientId)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $repoRoot)
$envPath = Join-Path $projectRoot '.env'
$config = @{}
foreach ($line in [IO.File]::ReadAllLines($envPath)) {
    if ($line -match '^([A-Z0-9_]+)=(.*)$') { $config[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'") }
}
if (-not $config['WAKEMATE_ADMIN_PASSWORD']) { throw 'Start WakeMate before configuring XiaoZhi.' }
$port = if ($config['WAKEMATE_PORT']) { $config['WAKEMATE_PORT'] } else { '8090' }
$baseUrl = "http://127.0.0.1:$port"
$loginBody = @{username='admin'; password=$config['WAKEMATE_ADMIN_PASSWORD']} | ConvertTo-Json
$login = Invoke-RestMethod "$baseUrl/api/auth/password" -Method Post -ContentType 'application/json' -Body $loginBody
$headers = @{Authorization=('Bearer ' + $login.access_token)}
$patients = @(Invoke-RestMethod "$baseUrl/api/admin/patients" -Headers $headers) | Where-Object { $_.role -eq 'patient' }
if (-not $patients) { throw 'Create a patient account in the administration UI first.' }
if (-not $PatientId) {
    $patients | Select-Object id,display_name,phone_masked | Format-Table | Out-Host
    $PatientId = Read-Host 'Patient ID to bind'
}
if (-not ($patients | Where-Object { $_.id -eq $PatientId })) { throw 'Patient ID is not an active patient account.' }
$endpointInput = Read-Host 'Paste the XiaoZhi MCP WSS endpoint (input hidden)' -AsSecureString
$endpoint = [Net.NetworkCredential]::new('', $endpointInput).Password.Trim()
$parsedEndpoint = $null
if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$parsedEndpoint) -or $parsedEndpoint.Scheme -ne 'wss' -or -not $parsedEndpoint.Host -or $parsedEndpoint.UserInfo -or $parsedEndpoint.Fragment) {
    throw 'A valid wss:// endpoint without user information is required.'
}
if ($endpoint -match '[\r\n\x00"''\\]' -or $endpoint.Contains('$')) { throw 'Endpoint contains characters not supported by dotenv.' }
$bindingBody = @{patient_id=$PatientId;label='Local XiaoZhi connector';endpoint=$endpoint} | ConvertTo-Json
$binding = Invoke-RestMethod "$baseUrl/api/admin/mcp-bindings" -Method Post -Headers $headers -ContentType 'application/json' -Body $bindingBody
$binding.token = $null
$endpoint = $null
$bindingBody = $null
$dockerArgs = @('compose','--env-file',$envPath)
$publicEnvPath = Join-Path $repoRoot '.public-deployment/tunnel.env'
if (Test-Path -LiteralPath $publicEnvPath) { $dockerArgs += @('--env-file',$publicEnvPath) }
$dockerArgs += @('-f',(Join-Path $repoRoot 'compose.yml'))
if (Test-Path -LiteralPath $publicEnvPath) { $dockerArgs += @('-f',(Join-Path $repoRoot 'compose.public.yml')) }
$dockerArgs += @('up','-d','--no-deps','--wait','--wait-timeout','120','mcp-manager')
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw 'MCP configuration saved, but manager startup failed. Check Docker status.' }
Write-Output ('Connector configured for patient ' + $PatientId + '. Binding ID: ' + $binding.id)
Write-Output 'Check Docker health and the XiaoZhi tool list before treating the connection as available.'
