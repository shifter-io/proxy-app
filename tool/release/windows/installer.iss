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

function DownloadToken(): String;
var
  Name, Token: String;
  Index: Integer;
begin
  Result := '';
  Name := Lowercase(ExtractFileName(ExpandConstant('{srcexe}')));
  if (Length(Name) <> 50) or (Copy(Name, 1, 14) <> 'shifter-setup-') or
     (Copy(Name, 47, 4) <> '.exe') then
    Exit;
  Token := Copy(Name, 15, 32);
  for Index := 1 to Length(Token) do
    if Pos(Token[Index], '0123456789abcdef') = 0 then Exit;
  Result := Token;
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
  if DownloadToken() <> '' then Params := Params + ' -Attribution ' + DownloadToken();
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
