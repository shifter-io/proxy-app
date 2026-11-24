param(
    [Parameter(Mandatory)][string] $Setup,
    [ValidatePattern('^[0-9a-f]{32}$')][string] $Attribution
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

if ($Attribution) {
    $directory = Join-Path $env:LOCALAPPDATA 'Shifter'
    New-Item -Path $directory -ItemType Directory -Force | Out-Null
    $attributionFile = Join-Path $directory 'install-attribution.txt'
    try {
        $file = [IO.File]::Open($attributionFile, [IO.FileMode]::CreateNew)
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes($Attribution)
            $file.Write($bytes, 0, $bytes.Length)
        } finally { $file.Dispose() }
    } catch [IO.IOException] {
        if (-not (Test-Path -LiteralPath $attributionFile)) { throw }
    }
}
