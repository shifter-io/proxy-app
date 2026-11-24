param(
    [Parameter(Mandatory)][string] $Setup,
    [ValidatePattern('^[0-9a-f]{32}$')][string] $Attribution
)
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Setup from a non-elevated Windows desktop.'
}
$sid = $principal.Identity.User.Value
$taskName = "Shifter.Tray.$sid"
$currentSession = (Get-Process -Id $PID).SessionId
if (Get-Process shifter_app -ErrorAction SilentlyContinue | Where-Object SessionId -eq $currentSession) {
    throw 'Quit Shifter from the notification area before running Setup.'
}

$result = Start-Process -FilePath $Setup -ArgumentList '--silent' -PassThru -Wait
if ($result.ExitCode -ne 0) { throw "Velopack Setup exited with code $($result.ExitCode)." }
$launcher = Join-Path $env:LOCALAPPDATA 'Shifter.ProxyApp\shifter_app.exe'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'The per-user launcher was not installed.' }

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

$action = New-ScheduledTaskAction -Execute $launcher -Argument '--background'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $principal.Identity.Name
$user = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $user `
    -Settings $settings -Force | Out-Null
# Let Task Scheduler own the process even on the initial install. A normal
# Start-menu launch sends activation to this instance.
Start-ScheduledTask -TaskName $taskName
