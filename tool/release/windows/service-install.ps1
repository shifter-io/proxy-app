param([switch] $Remove)
$ErrorActionPreference = 'Stop'
$name = 'ShifterBackground'
$service = Get-CimInstance Win32_Service -Filter "Name='$name'"
$path = Join-Path $PSScriptRoot 'ShifterService.exe'
$quotedPath = '"' + $path + '"'
if ($service -and $service.PathName -ne $quotedPath) {
    throw 'A Shifter service is registered at an unexpected path.'
}
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'

if ($Remove) {
    if ($service) {
        Stop-Service -Name $name
        & $sc delete $name
        if ($LASTEXITCODE -ne 0) { throw 'Could not deregister the Shifter service.' }
    }
    Get-ScheduledTask -TaskName 'Shifter.Tray.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Actions.Execute -like '*\Shifter.ProxyApp\current\shifter_app.exe' } |
        Unregister-ScheduledTask -Confirm:$false
    return
}

$signature = Get-AuthenticodeSignature -LiteralPath $path
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
    throw 'The Shifter background service signature did not verify.'
}
if (-not $service) {
    New-Service -Name $name -DisplayName 'Shifter Background Service' -BinaryPathName $quotedPath `
        -StartupType Automatic -Credential ([pscredential]::new('NT AUTHORITY\LocalService', [Security.SecureString]::new())) |
        Out-Null
}
& $sc failure $name 'reset=' 86400 'actions=' 'restart/5000/restart/15000/restart/60000'
if ($LASTEXITCODE -ne 0) { throw 'Could not configure Shifter service recovery.' }
Start-Service -Name $name
