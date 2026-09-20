param(
  [Parameter(Mandatory = $true)]
  [string] $AppVersion,

  [string] $SourceDir = "build\windows\x64\runner\Release",

  [string] $OutputDir = ".",

  # 安装包架构：x64（默认，保持既有行为）或 arm64（CI 的 ARM64 构建通道传入）。
  [ValidateSet("x64", "arm64")]
  [string] $SetupArch = "x64",

  [string] $InnoSetupCompiler = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$installerScript = Join-Path $repoRoot "scripts\windows\kelivo_installer.iss"

# 快捷方式与文件类型图标的来源。安装脚本会把这份文件以带版本号的名字装进目标目录，
# 让系统读不到旧的图标记录（原因见 kelivo_installer.iss 开头的说明）。
$iconSource = Join-Path $repoRoot "windows\runner\resources\app_icon.ico"
if (-not (Test-Path $iconSource)) {
  throw "Icon source not found: $iconSource"
}

if (-not (Test-Path $installerScript)) {
  throw "Inno Setup script not found: $installerScript"
}

if (-not (Test-Path $SourceDir)) {
  throw "Windows release bundle not found: $SourceDir"
}

$sourceDirResolved = (Resolve-Path $SourceDir).Path
$outputDirResolved = if (Test-Path $OutputDir) {
  (Resolve-Path $OutputDir).Path
} else {
  (Resolve-Path (New-Item -ItemType Directory -Force -Path $OutputDir)).Path
}

if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler)) {
  $candidatePaths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
  )

  $InnoSetupCompiler = $candidatePaths |
    Where-Object { $_ -and (Test-Path $_) } |
    Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler) -or
    -not (Test-Path $InnoSetupCompiler)) {
  throw "Inno Setup compiler not found. Install Inno Setup 6 or pass -InnoSetupCompiler explicitly."
}

Write-Host "Using Inno Setup compiler: $InnoSetupCompiler"

$innoSetupDir = Split-Path -Parent $InnoSetupCompiler
$zhLangCompiler = Join-Path $innoSetupDir "Languages\ChineseSimplified.isl"
$zhLangLocalDir = Join-Path $repoRoot "build\installer-languages"
$zhLangLocal = Join-Path $zhLangLocalDir "ChineseSimplified.isl"
$chineseMessagesFile = $null

if (Test-Path $zhLangCompiler) {
  Write-Host "Detected Chinese language file: $zhLangCompiler"
  $chineseMessagesFile = $zhLangCompiler
} elseif (Test-Path $zhLangLocal) {
  Write-Host "Using cached Chinese language file: $zhLangLocal"
  $chineseMessagesFile = $zhLangLocal
} else {
  Write-Host "Chinese language file is missing from Inno Setup. Downloading a local copy..."
  New-Item -ItemType Directory -Force -Path $zhLangLocalDir | Out-Null
  $uri = "https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages/ChineseSimplified.isl"
  Invoke-WebRequest -Uri $uri -OutFile $zhLangLocal -UseBasicParsing -TimeoutSec 60

  if (-not (Test-Path $zhLangLocal)) {
    throw "Chinese language file download did not create: $zhLangLocal"
  }
  Write-Host "Downloaded Chinese language file: $zhLangLocal"
  $chineseMessagesFile = $zhLangLocal
}

New-Item -ItemType Directory -Force -Path $outputDirResolved | Out-Null

$arguments = @(
  "/DAppVersion=$AppVersion",
  "/DSourceDir=$sourceDirResolved",
  "/DOutputDir=$outputDirResolved",
  "/DIconSource=$iconSource",
  "/DSetupArch=$SetupArch"
)

if ($chineseMessagesFile) {
  $arguments += "/DChineseMessagesFile=$chineseMessagesFile"
}

$arguments += $installerScript

& $InnoSetupCompiler @arguments

if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compiler failed with exit code $LASTEXITCODE"
}
