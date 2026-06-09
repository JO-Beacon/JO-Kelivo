$ErrorActionPreference = 'Stop'

function Replace-InFile([string]$Path, [string]$Pattern, [string]$Replacement) {
  if (!(Test-Path -LiteralPath $Path)) {
    Write-Host "Missing for replace: $Path"
    return
  }
  $text = Get-Content -LiteralPath $Path -Raw
  $text = [regex]::Replace($text, $Pattern, $Replacement)
  Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
}

$releaseLog = 'Release' + [char]0x65E5 + [char]0x5FD7 + '.md'

Replace-InFile 'README.md' '0\.1\.2\+2' '0.1.3+3'
Replace-InFile $releaseLog '基于原版 Kelivo 的非官方修改版本' '基于原版 Kelivo 1.1.16 的非官方修改版本'

Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_android_0\.2\.0\+3_armeabi-v7a\.apk' 'JO-Kelivo-v0.2.0+3-android-armeabi-v7a-release.apk'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_android_0\.2\.0\+3_arm64-v8a\.apk' 'JO-Kelivo-v0.2.0+3-android-arm64-v8a-release.apk'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_windows_0\.2\.0\+3\.zip' 'JO-Kelivo-v0.2.0+3-windows-x64-portable.zip'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_windows_0\.2\.0\+3_setup\.exe' 'JO-Kelivo-v0.2.0+3-windows-x64-setup.exe'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_macos_0\.2\.0\+3\.dmg' 'JO-Kelivo-v0.2.0+3-macos-universal-dmg.dmg'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_linux_0\.2\.0\+3\.tar\.gz' 'JO-Kelivo-v0.2.0+3-linux-x64-tar.gz'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_linux_0\.2\.0\+3\.AppImage' 'JO-Kelivo-v0.2.0+3-linux-x64-appimage.AppImage'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_android_0\.2\.0\+3_arm64-v8a\.apk\.sha256' 'JO-Kelivo-v0.2.0+3-android-arm64-v8a-release.apk.sha256'

Write-Host 'stage2 follow-up replacements complete'
