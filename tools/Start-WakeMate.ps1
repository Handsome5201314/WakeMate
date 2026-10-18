param([switch]$Build, [switch]$Xiaozhi)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $repoRoot)
$envPath = Join-Path $projectRoot '.env'
$existing = if (Test-Path -LiteralPath $envPath) { [IO.File]::ReadAllText($envPath) } else { '' }
function New-Secret {
    $buffer = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    $generator.GetBytes($buffer)
    $generator.Dispose()
    return [Convert]::ToBase64String($buffer).Replace('+','-').Replace('/','_').TrimEnd('=')
}
$lines = @()
foreach ($key in @('WAKEMATE_DB_PASSWORD','WAKEMATE_SECRET','WAKEMATE_ADMIN_PASSWORD')) {
    if ($existing -notmatch "(?m)^${key}=") { $lines += ($key + '=' + (New-Secret)) }
}
if ($existing -notmatch '(?m)^WAKEMATE_PORT=') { $lines += 'WAKEMATE_PORT=8090' }
if ($lines.Count -gt 0) {
    [IO.File]::AppendAllText($envPath, "`n" + ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
}
$dockerArgs = @('compose','--env-file',$envPath)
$publicEnvPath = Join-Path $repoRoot '.public-deployment/tunnel.env'
if (Test-Path -LiteralPath $publicEnvPath) { $dockerArgs += @('--env-file',$publicEnvPath) }
$dockerArgs += @('-f',(Join-Path $repoRoot 'compose.yml'))
if (Test-Path -LiteralPath $publicEnvPath) { $dockerArgs += @('-f',(Join-Path $repoRoot 'compose.public.yml')) }
if ($Xiaozhi) { $dockerArgs += @('--profile','xiaozhi') }
$dockerArgs += @('up','-d','--wait','--wait-timeout','120')
if ($Build) { $dockerArgs += '--build' }
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose startup failed' }
Write-Output 'WakeMate started. Administrator: admin. Password: WAKEMATE_ADMIN_PASSWORD in the project .env.'
