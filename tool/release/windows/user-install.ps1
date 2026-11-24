param(
    [Parameter(Mandatory)][string] $Setup
)
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Setup from a non-elevated Windows desktop.'
}
$currentSession = (Get-Process -Id $PID).SessionId
if (Get-Process shifter_app -ErrorAction SilentlyContinue | Where-Object SessionId -eq $currentSession) {
    throw 'Quit Shifter from the notification area before running Setup.'
}

$result = Start-Process -FilePath $Setup -ArgumentList '--silent' -PassThru -Wait
if ($result.ExitCode -ne 0) { throw "Velopack Setup exited with code $($result.ExitCode)." }
$runner = Join-Path $env:LOCALAPPDATA 'Shifter.ProxyApp\current\shifter_app.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'The per-user app was not installed.' }
