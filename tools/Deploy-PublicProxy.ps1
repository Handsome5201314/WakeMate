param([string]$SourceEnvPath = 'E:/AI新青年/Dravet 夜间连续监护/.env')
$ErrorActionPreference = 'Stop'
$settings = @{}
foreach ($line in Get-Content -LiteralPath $SourceEnvPath) {
    if ($line -match '^\s*(ALIBABA_SERVER_IP|ALIBABA_SSH_USER|ALIBABA_SSH_KEY)\s*=(.*)$') {
        $settings[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'")
    }
}
$address = $null
if (-not [Net.IPAddress]::TryParse($settings['ALIBABA_SERVER_IP'], [ref]$address)) {
    throw 'A valid server IP is required.'
}
if ($settings['ALIBABA_SSH_USER'] -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'Invalid SSH user.' }
if (-not (Test-Path -LiteralPath $settings['ALIBABA_SSH_KEY'] -PathType Leaf)) { throw 'SSH key file unavailable.' }
$source = Join-Path $PSScriptRoot 'public-proxy'
$configuration = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $source 'wakemate.caddy')))
$script = [IO.File]::ReadAllText((Join-Path $source 'deploy.py'))
$target = $settings['ALIBABA_SSH_USER'] + '@' + $settings['ALIBABA_SERVER_IP']
$script | & ssh -i $settings['ALIBABA_SSH_KEY'] -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 $target "python3 - $configuration"
if ($LASTEXITCODE -ne 0) { throw 'Public proxy deployment failed.' }
