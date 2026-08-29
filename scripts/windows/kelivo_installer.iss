#define MyAppName "JO-AIClient"
#define MyAppPublisher "Psyche"
#define MyAppExeName "jo_kelivo.exe"
#define MyAppId "{{D4C6D2A7-8F3E-4D7B-9D55-6B6B6D2E5A91}}"

#ifndef AppVersion
  #error AppVersion must be provided, for example: ISCC.exe /DAppVersion=0.1.3+3 scripts\windows\kelivo_installer.iss
#endif

#ifndef SourceDir
  #define SourceDir "build\windows\x64\runner\Release"
#endif

#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir={#OutputDir}
OutputBaseFilename=JO-Kelivo-v{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
ChangesAssociations=yes
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
#ifdef ChineseMessagesFile
Name: "chinesesimplified"; MessagesFile: "{#ChineseMessagesFile}"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.FileAssociationTask=关联 .joaiclient 文件
chinesesimplified.FileAssociationGroup=文件关联:
english.FileAssociationTask=Associate .joaiclient files
english.FileAssociationGroup=File associations:

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"
Name: "fileassociation"; Description: "{cm:FileAssociationTask}"; GroupDescription: "{cm:FileAssociationGroup}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
Root: HKCR; Subkey: ".joaiclient"; ValueType: string; ValueName: ""; ValueData: "JOAIClient.Backup"; Flags: uninsdeletevalue; Tasks: fileassociation
Root: HKCR; Subkey: "JOAIClient.Backup"; ValueType: string; ValueName: ""; ValueData: "JO-AIClient 备份文件"; Flags: uninsdeletekey; Tasks: fileassociation
Root: HKCR; Subkey: "JOAIClient.Backup\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"; Tasks: fileassociation
Root: HKCR; Subkey: "JOAIClient.Backup\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Tasks: fileassociation

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
