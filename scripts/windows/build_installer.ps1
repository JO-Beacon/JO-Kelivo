param(
  [Parameter(Mandatory = $true)]
  [string] $AppVersion,

  [string] $SourceDir = "build\windows\x64\runner\Release",

  [string] $OutputDir = ".",

  [string] $InnoSetupCompiler = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$installerScript = Join-Path $repoRoot "scripts\windows\kelivo_installer.iss"

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
} else {
  Write-Host "Chinese language file is missing from Inno Setup. Downloading a local copy..."
  New-Item -ItemType Directory -Force -Path $zhLangLocalDir | Out-Null
  $uri = "https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages/Unofficial/ChineseSimplified.isl"

  try {
    Invoke-WebRequest -Uri $uri -OutFile $zhLangLocal -UseBasicParsing -TimeoutSec 60
  } catch {
    Write-Host "Failed to download Chinese language file: $($_.Exception.Message)"
  }

  if (Test-Path $zhLangLocal) {
    Write-Host "Downloaded Chinese language file: $zhLangLocal"
    $chineseMessagesFile = $zhLangLocal
  } else {
    Write-Host "Chinese language file unavailable. Falling back to English installer messages."
  }
}

New-Item -ItemType Directory -Force -Path $outputDirResolved | Out-Null

$arguments = @(
  "/DAppVersion=$AppVersion",
  "/DSourceDir=$sourceDirResolved",
  "/DOutputDir=$outputDirResolved"
)

if ($chineseMessagesFile) {
  $arguments += "/DChineseMessagesFile=$chineseMessagesFile"
}

$arguments += $installerScript

& $InnoSetupCompiler @arguments

if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compiler failed with exit code $LASTEXITCODE"
}
