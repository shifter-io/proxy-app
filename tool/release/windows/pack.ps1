param(
    [Parameter(Mandatory)][string] $Bundle,
    [Parameter(Mandatory)][string] $BuildRoot,
    [Parameter(Mandatory)][string] $Output,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string] $Version,
    [Parameter(Mandatory)][string] $AzureMetadata,
    [Parameter(Mandatory)][string] $SignTool,
    [Parameter(Mandatory)][string] $AzureDlib,
    [Parameter(Mandatory)][string] $Publisher,
    [Parameter(Mandatory)][string] $InnoCompiler,
    [string] $Vpk = 'vpk'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Tool([string] $Program, [string[]] $ToolArguments) {
    & $Program @ToolArguments
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Program)) failed ($LASTEXITCODE)." }
}

function Assert-Signed([string] $File) {
    $signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne $Publisher) {
        throw "The signature or timestamp on $([IO.Path]::GetFileName($File)) did not verify."
    }
    Invoke-Tool $SignTool @('verify','/pa','/v',$File)
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
$AzureMetadata = (Resolve-Path -LiteralPath $AzureMetadata).Path
$SignTool = (Resolve-Path -LiteralPath $SignTool).Path
$AzureDlib = (Resolve-Path -LiteralPath $AzureDlib).Path
$InnoCompiler = (Resolve-Path -LiteralPath $InnoCompiler).Path
$runner = Join-Path $Bundle 'shifter_app.exe'
$runnerVersion = (Get-Item -LiteralPath $runner).VersionInfo
$productVersion = '{0}.{1}.{2}' -f $runnerVersion.ProductMajorPart, $runnerVersion.ProductMinorPart, $runnerVersion.ProductBuildPart
if ($productVersion -ne $Version) {
    throw 'The Flutter runner version does not match the Velopack release version.'
}
if ((& $Vpk --help | Out-String) -notmatch '\b1\.2\.161\b') { throw 'Use Velopack CLI 1.2.161.' }
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Output = (Resolve-Path -LiteralPath $Output).Path
if (Get-ChildItem -LiteralPath $Output -Force) { throw 'Use an empty output directory.' }
$stage = Join-Path $Output 'package'
New-Item -ItemType Directory -Path $stage | Out-Null

New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
if ($BuildRoot -match '(?i)(^|[\/])(Desktop|Documents|OneDrive|Dropbox)([\/]|$)') {
    throw 'Build the updater in a local cache outside synced folders.'
}
$env:CARGO_TARGET_DIR = Join-Path $BuildRoot 'rust'
Invoke-Tool 'cargo' @('build','--locked','--release','--target','x86_64-pc-windows-msvc',
    '--manifest-path',(Join-Path $repo 'native\updater\Cargo.toml'))
Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'x86_64-pc-windows-msvc\release\shifter_updater.dll') -Destination $Bundle -Force
Invoke-Tool $Vpk @('pack','--packId','Shifter.ProxyApp','--packTitle','Shifter',
    '--packVersion',$Version,'--packDir',$Bundle,'--mainExe','shifter_app.exe',
    '--runtime','win-x64','--channel','stable','--delta','None','--outputDir',$stage,
    '--azureTrustedSignFile',$AzureMetadata)
$inner = @(Get-ChildItem -LiteralPath $stage -File -Filter '*Setup.exe')
$full = @(Get-ChildItem -LiteralPath $stage -File -Filter '*-full.nupkg')
if ($inner.Count -ne 1 -or $full.Count -ne 1) { throw 'Expected one setup and one full package.' }
Assert-Signed $inner[0].FullName

Add-Type -AssemblyName System.IO.Compression.FileSystem
$inspection = Join-Path $stage 'inspection'
[IO.Compression.ZipFile]::ExtractToDirectory($full[0].FullName, $inspection)
foreach ($name in @('shifter_app.exe','shifter_updater.dll','Shifter_ExecutionStub.exe','Squirrel.exe')) {
    $entry = @(Get-ChildItem -LiteralPath $inspection -Recurse -File -Filter $name)
    if ($entry.Count -ne 1) { throw "Expected one packaged $name." }
    Assert-Signed $entry[0].FullName
}

Move-Item -LiteralPath $inner[0].FullName -Destination (Join-Path $stage 'Shifter-Velopack-Setup.exe')
$timestamp = 'http://timestamp.acs.microsoft.com'
$template = '$q' + $SignTool + '$q sign /fd SHA256 /td SHA256 /tr ' + $timestamp +
    ' /dlib $q' + $AzureDlib + '$q /dmdf $q' + $AzureMetadata + '$q $f'
Invoke-Tool $InnoCompiler @(('/SAzure=' + $template), ('/DStageDir=' + $stage),
    ('/DOutputDir=' + $Output), ('/DReleaseVersion=' + $Version), (Join-Path $PSScriptRoot 'installer.iss'))
$installer = Join-Path $Output 'Shifter-Setup-win-x64.exe'
Assert-Signed $installer
$feedPackage = Join-Path $Output $full[0].Name
Move-Item -LiteralPath $full[0].FullName -Destination $feedPackage
$receipt = [ordered]@{
    commit = (& git -C $repo rev-parse HEAD)
    version = $Version
    velopack = '1.2.161'
    publisher = $Publisher
    files = @(Get-FileHash -LiteralPath $installer,$feedPackage | ForEach-Object {
        @{ file = (Split-Path $_.Path -Leaf); sha256 = $_.Hash.ToLowerInvariant() }
    })
}
$receipt | ConvertTo-Json | Set-Content (Join-Path $Output 'build-receipt.json') -Encoding UTF8
