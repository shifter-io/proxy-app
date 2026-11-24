$ErrorActionPreference = 'Stop'
$installRoot = Join-Path $env:LOCALAPPDATA 'Shifter.ProxyApp'
$runner = Join-Path $installRoot 'current\shifter_app.exe'
$updater = Join-Path $installRoot 'Update.exe'
$session = (Get-Process -Id $PID).SessionId

function Find-ShifterProcess([string] $Path) {
    Get-Process ([IO.Path]::GetFileNameWithoutExtension($Path)) -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session -and $_.Path -eq $Path } |
        Select-Object -First 1
}

$launch = @{
    FilePath = $runner
    WorkingDirectory = Split-Path $runner -Parent
    ArgumentList = '--background'
    PassThru = $true
}
$app = Start-Process @launch
$retries = 0
while ($app) {
    $app.WaitForExit()
    if ($app.ExitCode -eq 0) {
        # Velopack launches its updater before the old app exits. Adopt the
        # replacement if one starts. Explicit Quit leaves no replacement.
        $update = Find-ShifterProcess $updater
        if ($update -and -not $update.WaitForExit(120000)) { exit 1 }
        $app = Find-ShifterProcess $runner
        continue
    }
    if ($retries -eq 3) { exit 1 }
    $retries++
    Start-Sleep -Seconds 5
    $app = Start-Process @launch
}
