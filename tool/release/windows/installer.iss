; Velopack owns the per-user application and its uninstaller.
[Setup]
AppId=Shifter.ProxyApp
AppName=Shifter Proxy App
AppVersion={#ReleaseVersion}
AppPublisher=Shifter
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Shifter-Setup-win-x64
SolidCompression=yes
Compression=lzma2
SignTool=Azure
CloseApplications=no
RestartApplications=no

[Files]
Source: "{#StageDir}\Shifter-Velopack-Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "user-install.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Run]
Filename: "{localappdata}\Shifter.ProxyApp\Shifter.exe"; Description: "Launch Shifter"; Flags: nowait postinstall skipifsilent; Check: InstallationSucceeded

[Code]
var
  InstallationError: String;

function PowerShell(): String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function InstallationSucceeded(): Boolean;
begin
  Result := InstallationError = '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  Params: String;
begin
  if CurStep <> ssPostInstall then Exit;
  Params := ExpandConstant('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{tmp}\user-install.ps1" -Setup "{tmp}\Shifter-Velopack-Setup.exe"');
  if not Exec(PowerShell(), Params, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
    InstallationError := 'Shifter could not install the per-user app. Run Setup from a normal Windows desktop and quit any running Shifter app first.';
  if InstallationError <> '' then Log(InstallationError);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and (InstallationError <> '') then begin
    WizardForm.FinishedHeadingLabel.Caption := 'Shifter setup needs repair';
    WizardForm.FinishedLabel.Caption := InstallationError;
  end;
end;

function GetCustomSetupExitCode(): Integer;
begin
  Result := 0;
  if InstallationError <> '' then Result := 10;
end;
