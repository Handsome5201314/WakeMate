param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $repoRoot)
$envPath = Join-Path $projectRoot '.env'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'backups' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$dockerArguments = @('compose','--env-file',$envPath,'-f',(Join-Path $repoRoot 'compose.yml'))
$container = (& docker @dockerArguments ps -q db).Trim()
if ($LASTEXITCODE -ne 0 -or -not $container) { throw 'WakeMate database container is unavailable.' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$temporary = '/tmp/wakemate-' + [Guid]::NewGuid().ToString('N') + '.dump'
$destination = Join-Path $OutputDirectory ('wakemate-' + $stamp + '.dump')
try {
    & docker @dockerArguments exec -T db pg_dump -U wakemate -d wakemate -Fc --file $temporary
    if ($LASTEXITCODE -ne 0) { throw 'Database backup failed.' }
    & docker @dockerArguments exec -T db pg_restore --list $temporary | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Database backup archive validation failed.' }
    & docker cp "${container}:$temporary" $destination
    if ($LASTEXITCODE -ne 0) { throw 'Could not transfer the database backup.' }
    Write-Output ('Verified PostgreSQL backup: ' + $destination)
} finally {
    & docker @dockerArguments exec -T db rm -f $temporary
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not remove the temporary database backup inside the container.' }
}
