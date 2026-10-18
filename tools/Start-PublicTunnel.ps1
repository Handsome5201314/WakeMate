param(
    [string]$EnvPath = 'E:\AI新青年\Dravet 夜间连续监护\.env',
    [switch]$Build
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $repoRoot)
$projectEnvPath = Join-Path $projectRoot '.env'

foreach ($requiredPath in @($EnvPath, $projectEnvPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw 'The source or WakeMate environment file is unavailable.'
    }
}
$sourceEnvPath = (Resolve-Path -LiteralPath $EnvPath).Path
$sourceValues = @{}
foreach ($line in [IO.File]::ReadAllLines($sourceEnvPath)) {
    if ($line -match '^\s*(ALIBABA_SERVER_IP|ALIBABA_SSH_USER|ALIBABA_SSH_KEY)\s*=(.*)$') {
        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        )) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $sourceValues[$name] = $value
    }
}
foreach ($name in @('ALIBABA_SERVER_IP', 'ALIBABA_SSH_USER', 'ALIBABA_SSH_KEY')) {
    if (-not $sourceValues[$name]) { throw "The source environment is missing $name." }
}
$serverAddress = $null
if (-not [Net.IPAddress]::TryParse($sourceValues['ALIBABA_SERVER_IP'], [ref]$serverAddress)) {
    throw 'ALIBABA_SERVER_IP must be a valid IP address.'
}
if ($sourceValues['ALIBABA_SSH_USER'] -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*$') {
    throw 'ALIBABA_SSH_USER is invalid.'
}
$sshKeyPath = [Environment]::ExpandEnvironmentVariables($sourceValues['ALIBABA_SSH_KEY'])
if ($sshKeyPath.StartsWith('~/') -or $sshKeyPath.StartsWith('~\')) {
    $sshKeyPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) $sshKeyPath.Substring(2)
} elseif (-not [IO.Path]::IsPathRooted($sshKeyPath)) {
    $sshKeyPath = Join-Path (Split-Path -Parent $sourceEnvPath) $sshKeyPath
}
if (-not (Test-Path -LiteralPath $sshKeyPath -PathType Leaf)) {
    throw 'The configured SSH private key file is unavailable.'
}
$sshKeyPath = (Resolve-Path -LiteralPath $sshKeyPath).Path
$knownHostsPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh/known_hosts'
if (-not (Test-Path -LiteralPath $knownHostsPath -PathType Leaf)) {
    throw 'The existing SSH known_hosts file is unavailable.'
}
$hostRecords = @(& ssh-keygen -F $sourceValues['ALIBABA_SERVER_IP'] -f $knownHostsPath 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'No previously verified SSH host key exists for this server.' }
$hostRecords = @($hostRecords | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($hostRecords.Count -eq 0) { throw 'No previously verified SSH host key exists for this server.' }

$deploymentDir = Join-Path $repoRoot '.public-deployment'
New-Item -ItemType Directory -Path $deploymentDir -Force | Out-Null
$tunnelKnownHostsPath = Join-Path $deploymentDir 'known_hosts'
[IO.File]::WriteAllText(
    $tunnelKnownHostsPath, ($hostRecords -join "`n") + "`n", (New-Object Text.UTF8Encoding($false))
)
$tunnelEnvironment = @{
    WAKEMATE_SSH_HOST = $sourceValues['ALIBABA_SERVER_IP']
    WAKEMATE_SSH_USER = $sourceValues['ALIBABA_SSH_USER']
    WAKEMATE_SSH_KEY_PATH = $sshKeyPath
    WAKEMATE_SSH_KNOWN_HOSTS_PATH = $tunnelKnownHostsPath
}
$tunnelEnvPath = Join-Path $deploymentDir 'tunnel.env'
$tunnelLines = @()
foreach ($name in ($tunnelEnvironment.Keys | Sort-Object)) {
    $value = $tunnelEnvironment[$name].Replace('\', '/').Replace("'", "\'")
    $tunnelLines += "$name='$value'"
}
[IO.File]::WriteAllText(
    $tunnelEnvPath, ($tunnelLines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false))
)
$dockerArgs = @(
    'compose', '-p', 'wakemate', '--env-file', $projectEnvPath, '--env-file', $tunnelEnvPath,
    '-f', (Join-Path $repoRoot 'compose.yml'),
    '-f', (Join-Path $repoRoot 'compose.public.yml'),
    'up', '-d', '--no-deps', '--wait', '--wait-timeout', '120'
)
if ($Build) { $dockerArgs += '--build' }
$dockerArgs += @('api', 'public-tunnel')
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw 'WakeMate public tunnel startup failed.' }
Write-Output 'WakeMate API and its public SSH tunnel are healthy.'
