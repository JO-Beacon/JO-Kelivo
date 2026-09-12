#define MyAppName "JO-AIClient"
#define MyAppPublisher "JO-Beacon"
#define MyAppExeName "jo_aiclient.exe"
#define MyAppId "{{4DAB8FFA-513A-4729-9A93-82207E2F2785}}"

#ifndef AppVersion
  #error AppVersion must be provided, for example: ISCC.exe /DAppVersion=0.1.3+3 scripts\windows\kelivo_installer.iss
#endif

#ifndef SourceDir
  #define SourceDir "build\windows\x64\runner\Release"
#endif

#ifndef OutputDir
  #define OutputDir "."
#endif

; 快捷方式与文件类型图标改用一份独立的 .ico，装进目标目录时文件名带版本号。
;
; 为什么必须让文件名变：Windows 的图标记录按“图标来源的文件路径”记账，而且没有任何
; 接口能让这条记录失效（三条通知接口与 ie4uinit 均实测无效，见 build/probes/iconcache_lab.py）。
; 若图标继续隐含取自程序的第 0 号图标，路径与序号在升级前后都不变，系统就一直命中旧记录，
; 桌面快捷方式会一直显示升级前的图形。文件名随版本变化后，系统查不到记录，只能读真图。
;
; 默认值是按“主脚本所在目录”推算的（正常构建时主脚本就是本文件，位于 scripts\windows\）。
; 构建脚本始终传绝对路径覆盖它，所以这只是手工编译时的兜底。
; 注意：若用另一个脚本 #include 本文件，这个相对路径会按那个脚本的位置算，可能指错。
#ifndef IconSource
  #define IconSource "..\..\windows\runner\resources\app_icon.ico"
#endif
#ifndef IconDestName
  #define IconDestName "app_icon_" + AppVersion + ".ico"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
; 安装范围交给用户在安装时选：为所有用户（需管理员）或仅为我，默认推荐“仅为我”。
; 默认“仅为我”的理由：公共桌面只有管理员能写，应用改不动那里的快捷方式，
; 桌面图标就没法随主题实时切换；装到用户自己的桌面才有可能。
; 下面两处“自动”常量会跟着安装模式变：{autopf}（程序目录）与 {autodesktop}（桌面）。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=JO-AIClient-v{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
ChangesAssociations=yes
; 旧版本还在运行时，允许安装程序直接结束它。但安装程序不会悄悄动手：
; [Code] 段的 PrepareToInstall 会先弹一个三按钮对话框，由用户决定怎么处理。
;
; 这里刻意不用 AppMutex 指令。它在安装程序一启动就拦住，后面的自动关闭永远轮不到执行，
; 等于“让用户知情”和“能一键强制关”只能二选一。改成自己在复制文件之前查一次，两者就都有。
; 检测用的互斥体由程序自己创建（windows/runner/main.cpp 的 CreateMutexW，
; 名字 JOAIClientMutex，大小写敏感、无 Global\ 前缀）。
;
; 代价：强制结束会绕过程序的退出排空（lib/core/services/app_exit_flush.dart 挂在正常退出
; 时机上），那一刻未落盘的写入会丢。所以对话框里必须写清楚，由用户自己权衡。
CloseApplications=force
UninstallDisplayIcon={app}\{#IconDestName}

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

; 程序运行中的对话框文案。默认那套提示（SetupAppRunningError）只在用 AppMutex 指令时才会
; 出现，而本安装程序改用了 [Code] 段自己判断，所以那两条消息与 [Messages] 段已一并移除。
; 文案里必须点明“从托盘退出”：本程序关闭窗口后只是缩进通知区域、并不退出，
; 用户照默认说法点关闭会一直卡在这里出不去。
;
; 三个按钮的定位（2026-09-12 用户拍板）：强制结束是“无法自行关闭”时的备选，必须写明它
; 直接销毁进程、不走正常退出的收尾，会被中断与丢失的分别是哪些；自行关闭才是推荐路径，
; 要写明它属于正常退出、程序会先把未保存的数据写下去。
;
; 正文拆成三段、由代码用换行符拼接，而不是在这里写 %n：%n 是消息展开语法，
; 从 [Code] 段取出时是否已被处理没有把握，拆开写就不依赖它。
chinesesimplified.AppRunningTitle=检测到 {#MyAppName} 正在运行
chinesesimplified.AppRunningBodyInstall=安装需要替换程序文件，得先结束它。
chinesesimplified.AppRunningBodyUninstall=卸载需要删除程序文件，得先结束它。
chinesesimplified.AppRunningBodyWarn=选择“强制结束它并继续”不是正常退出，而是直接销毁进程：程序来不及收尾保存，正在生成的回复最后一段、刚改过还没写盘的设置都可能丢失，正在进行的备份或恢复会被中断。它只是无法自行关闭时才用的备选。
chinesesimplified.AppRunningBodySelf=选择“我自己关闭，重新检测”才是正常退出，程序会先把未保存的数据写下去：右键点击通知区域（托盘）的图标并选择“退出”，再回到本窗口点此按钮重新检测。
chinesesimplified.AppRunningForce=强制结束它并继续
chinesesimplified.AppRunningSelf=我自己关闭，重新检测
chinesesimplified.AppRunningCancel=取消安装
chinesesimplified.AppUninstallCancel=取消卸载
chinesesimplified.AppRunningCancelled=安装已取消：{#MyAppName} 仍在运行，程序文件无法替换。
chinesesimplified.AppRunningGaveUp=无法结束 {#MyAppName}，安装已停止。请手动退出它之后重试。

english.AppRunningTitle=JO-AIClient is currently running
english.AppRunningBodyInstall=Setup needs to replace the program files, so it must be closed first.
english.AppRunningBodyUninstall=Uninstall needs to delete the program files, so it must be closed first.
english.AppRunningBodyWarn=Choosing “Force-close it and continue” is not a normal exit: the process is destroyed outright, so the app gets no chance to save. The tail of a reply still being generated and any setting changed but not yet written to disk can be lost, and a backup or restore in progress is interrupted. Treat it as a fallback for when you cannot close the app yourself.
english.AppRunningBodySelf=Choosing “I will close it myself, check again” is a normal exit, so the app first writes down anything not saved yet: right-click its icon in the notification area (system tray) and choose “Exit”, then return to this window and click that button to check again.
english.AppRunningForce=Force-close it and continue
english.AppRunningSelf=I will close it myself, check again
english.AppRunningCancel=Cancel setup
english.AppUninstallCancel=Cancel uninstall
english.AppRunningCancelled=Setup was cancelled: JO-AIClient is still running, so the program files cannot be replaced.
english.AppRunningGaveUp=Could not close JO-AIClient; setup has stopped. Please exit it manually and try again.

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"
Name: "fileassociation"; Description: "{cm:FileAssociationTask}"; GroupDescription: "{cm:FileAssociationGroup}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "jo_kelivo.exe"; Flags: ignoreversion recursesubdirs createallsubdirs
; 图标单独装一份，文件名带版本号（见文件开头的说明）。这是快捷方式与文件类型图标的来源。
Source: "{#IconSource}"; DestDir: "{app}"; DestName: "{#IconDestName}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\jo_kelivo.exe"
; 清掉历史版本的图标，保证目标目录里只留当前这一份。
; 必须放在文件复制之前，且新版本的文件名与旧的不同，不会误删即将装入的那份。
Type: files; Name: "{app}\app_icon_*.ico"

[Registry]
; 根用 HKA：它在“为所有用户”安装时等于 HKLM、“仅为我”安装时等于 HKCU，
; 这样两种安装模式都不用改脚本（HKCR 需要管理员权限，非管理员安装时会失败）。
;
; ⚠️ HKA 等于 HKLM/HKCU **本身**，里面不含 Software\Classes 那一层，所以 Subkey 必须
; 自己带上 "Software\Classes\"。漏掉它会写到 HKLM 根下，系统直接拒绝：
; 实测 HKLM\.joaiclient 与 HKLM\joaiclient 都返回 87（参数错误），
; 而 HKLM\Software\Classes\.joaiclient 返回 5（拒绝访问，即路径有效、只是要管理员）。
Root: HKA; Subkey: "Software\Classes\.joaiclient"; ValueType: string; ValueName: ""; ValueData: "JOAIClient.Backup"; Flags: uninsdeletevalue; Tasks: fileassociation
Root: HKA; Subkey: "Software\Classes\JOAIClient.Backup"; ValueType: string; ValueName: ""; ValueData: "JO-AIClient 备份文件"; Flags: uninsdeletekey; Tasks: fileassociation
Root: HKA; Subkey: "Software\Classes\JOAIClient.Backup\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#IconDestName},0"; Tasks: fileassociation
Root: HKA; Subkey: "Software\Classes\JOAIClient.Backup\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Tasks: fileassociation

[Icons]
; 这两处快捷方式的图标不再隐含取自程序文件，而是明确指向带版本号的那份 .ico。
; 卸载快捷方式不指（它显示的是系统自带卸载图标，与本应用图形无关）。
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#IconDestName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#IconDestName}"; Tasks: desktopicon

[Run]
; 这里曾试过在安装收尾执行 ie4uinit.exe -show 刷新图标缓存，实测无效：
; 退出码为 0 但缓存文件零变化，桌面图标也不刷新（详见 build/probes/iconcache_lab2.py）。
; 同一路径上的图标记录无法通过任何通知接口失效，所以改由“让图标来源改名”来解决，
; 见文件开头关于 IconDestName 的说明。此处不再做无效动作。
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
{ 旧版本还在运行时，弹三按钮对话框由用户决定怎么处理。

  为什么不直接用 AppMutex 指令：它在安装程序启动阶段就拦住，用户只能“去关掉”或“取消”，
  没有第三条路；而且它一旦生效，CloseApplications=force 就永远轮不到执行。改成在这里自己查
  一次，三条路就都在。

  检测的互斥体由程序自身创建（windows/runner/main.cpp 的 CreateMutexW，名字大小写敏感）。
  程序还开着时该名字就存在，关掉后系统自动释放。 }

const
  APP_MUTEX = 'JOAIClientMutex';

{ 组合对话框正文：首段（安装 / 卸载各一句）由调用方给，后两段共用。
  换行在这里拼，不依赖消息里的 %n 展开。 }
function RunningAppBody(const Lead: String): String;
begin
  Result := Lead
    + #13#10 + #13#10 + ExpandConstant('{cm:AppRunningBodyWarn}')
    + #13#10 + #13#10 + ExpandConstant('{cm:AppRunningBodySelf}');
end;

{ 弹出对话框，返回用户的选择：1 = 强制结束、2 = 自行关闭（正常退出）、0 = 取消。
  CancelLabel 由调用方给：安装与卸载的措辞不同（取消安装 / 取消卸载）。 }
function AskHowToCloseRunningApp(const Body, CancelLabel: String): Integer;
var
  Labels: TArrayOfString;
  Answer: Integer;
begin
  SetArrayLength(Labels, 3);
  Labels[0] := ExpandConstant('{cm:AppRunningForce}');
  Labels[1] := ExpandConstant('{cm:AppRunningSelf}');
  Labels[2] := CancelLabel;

  { 最后一个参数 -1 表示不给任何按钮加管理员盾牌图标：这一步不需要提权。 }
  Answer := TaskDialogMsgBox(
    ExpandConstant('{cm:AppRunningTitle}'), Body,
    mbConfirmation, MB_YESNOCANCEL, Labels, -1);

  { 三按钮对话框的返回值是 IDYES / IDNO / IDCANCEL，分别对应上面三个标签。 }
  if Answer = IDYES then
    Result := 1
  else if Answer = IDNO then
    Result := 2
  else
    Result := 0;
end;

{ 安装：在复制文件之前处理旧进程。

  文档说明本事件在 CloseApplications 检查文件占用之前调用，所以这里放行之后，
  安装程序接着用重启管理器把占用文件的程序关掉（已设 force，不会只礼貌请求）。 }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Choice: Integer;
  Attempts: Integer;
begin
  Result := '';
  Attempts := 0;

  while CheckForMutexes(APP_MUTEX) do
  begin
    Attempts := Attempts + 1;
    { 兜底：避免一直关不掉时无限弹窗。正常情况第二、三次就该结束。 }
    if Attempts > 5 then
    begin
      Result := ExpandConstant('{cm:AppRunningGaveUp}');
      Exit;
    end;

    Choice := AskHowToCloseRunningApp(
      RunningAppBody(ExpandConstant('{cm:AppRunningBodyInstall}')),
      ExpandConstant('{cm:AppRunningCancel}'));
    if Choice = 1 then
    begin
      { 放行，交给 CloseApplications=force。它走 Windows 重启管理器，比外部命令规范。 }
      Exit;
    end
    else if Choice = 0 then
    begin
      Result := ExpandConstant('{cm:AppRunningCancelled}');
      Exit;
    end;
    { Choice = 2：用户自己关，给一点时间后重新检测。 }
    Sleep(1000);
  end;
end;

{ 卸载：同样要在删文件之前确认程序已退出。

  这里必须自己处理：CloseApplications 走的重启管理器只管安装，卸载时没有这套机制，
  程序还在运行就会删不掉主程序文件，因此上面那个 AppMutex 换成 [Code] 之后，卸载这边
  要补上等价的一环，否则是能力倒退。 }
function InitializeUninstall(): Boolean;
var
  Choice: Integer;
  Attempts: Integer;
  ResultCode: Integer;
begin
  Result := True;
  Attempts := 0;

  while CheckForMutexes(APP_MUTEX) do
  begin
    Attempts := Attempts + 1;
    if Attempts > 5 then
    begin
      Result := False;
      Exit;
    end;

    Choice := AskHowToCloseRunningApp(
      RunningAppBody(ExpandConstant('{cm:AppRunningBodyUninstall}')),
      ExpandConstant('{cm:AppUninstallCancel}'));
    if Choice = 1 then
    begin
      { 卸载没有重启管理器可用，只能直接结束进程（同安装侧 force 的代价）。 }
      Exec('taskkill.exe', '/F /IM {#MyAppExeName}', '', SW_HIDE,
           ewWaitUntilTerminated, ResultCode);
      Log('taskkill 结束旧进程，返回码 ' + IntToStr(ResultCode));
      Sleep(800);
    end
    else if Choice = 0 then
    begin
      Result := False;
      Exit;
    end
    else
      Sleep(1000);
  end;
end;
