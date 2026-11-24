; The elevated bootstrapper owns the service. Velopack still owns the per-user application.
[Setup]
AppId=ShifterBackground
AppName=Shifter Proxy App and Background Service
AppVersion={#ReleaseVersion}
AppPublisher=Shifter
DefaultDirName={autopf}\Shifter
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Shifter-Setup-win-x64
SolidCompression=yes
Compression=lzma2
SignTool=Azure
SignedUninstaller=yes
CloseApplications=no
RestartApplications=no

[Files]
Source: "{#StageDir}\ShifterService.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\Shifter-Velopack-Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "user-install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "service-install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "tray-run.ps1"; DestDir: "{app}"; Flags: ignoreversion

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

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if not Exec(PowerShell(), '-NoProfile -NonInteractive -Command "if (Get-Service ShifterBackground -ErrorAction SilentlyContinue) { Stop-Service ShifterBackground -ErrorAction Stop }"', '',
      SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
    Result := 'Shifter could not stop its background service. Close the app and retry.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  Params: String;
begin
  if CurStep <> ssPostInstall then Exit;
  Params := ExpandConstant('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{app}\user-install.ps1" -Setup "{tmp}\Shifter-Velopack-Setup.exe"');
  if DownloadToken() <> '' then Params := Params + ' -Attribution ' + DownloadToken();
  if not ExecAsOriginalUser(PowerShell(), Params, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
    InstallationError := 'Shifter could not install the per-user app. Run Setup from a normal Windows desktop and quit any running Shifter app first.';
  if (InstallationError = '') and (not Exec(PowerShell(), ExpandConstant('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{app}\service-install.ps1"'), '',
      SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0)) then
    InstallationError := 'Shifter installed the app but could not start its background service. Run Setup again to repair it.';
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

function InitializeUninstall(): Boolean;
var
  ExitCode: Integer;
begin
  Result := Exec(PowerShell(), ExpandConstant('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{app}\service-install.ps1" -Remove'), '',
      SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
  if not Result then MsgBox('The Shifter background service could not be removed. Close Shifter and retry.', mbError, MB_OK);
end;
