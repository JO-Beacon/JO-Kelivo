$ErrorActionPreference = 'Stop'

function Replace-InFile([string]$Path, [string]$Pattern, [string]$Replacement) {
  if (Test-Path -LiteralPath $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $text = [regex]::Replace($text, $Pattern, $Replacement)
    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
  } else {
    Write-Host "Missing for replace: $Path"
  }
}

function Copy-Old([string]$Path) {
  $src = Join-Path '参考文件/改版1.1.15/JO-Kelivo-0.1.2+2' $Path
  if (Test-Path -LiteralPath $src) {
    $dst = $Path
    $parent = Split-Path $dst -Parent
    if ($parent -and !(Test-Path -LiteralPath $parent)) {
      New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
  } else {
    Write-Host "Missing old source: $src"
  }
}

# Version and package identity
Replace-InFile 'pubspec.yaml' '^version: .*$' 'version: 0.1.3+3'
Replace-InFile 'android/app/build.gradle.kts' 'com\.psyche\.kelivo' 'com.psyche.jokelivo'
Replace-InFile 'android/app/src/main/AndroidManifest.xml' 'android:label="Kelivo"' 'android:label="JO-Kelivo"'
if (Test-Path -LiteralPath 'android/app/src/main/kotlin/com/psyche/kelivo') {
  if (Test-Path -LiteralPath 'android/app/src/main/kotlin/com/psyche/jokelivo') {
    Remove-Item -LiteralPath 'android/app/src/main/kotlin/com/psyche/jokelivo' -Recurse -Force
  }
  Move-Item -LiteralPath 'android/app/src/main/kotlin/com/psyche/kelivo' -Destination 'android/app/src/main/kotlin/com/psyche/jokelivo' -Force
}
Get-ChildItem -Path 'android/app/src/main/kotlin/com/psyche/jokelivo' -Filter '*.kt' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
  Replace-InFile $_.FullName 'com\.psyche\.kelivo' 'com.psyche.jokelivo'
}

# iOS/macOS identity
Replace-InFile 'ios/Runner/Info.plist' '<string>Kelivo</string>' '<string>JO-Kelivo</string>'
Replace-InFile 'ios/Runner/Info.plist' '<string>kelivo</string>' '<string>JO-Kelivo</string>'
Replace-InFile 'ios/Runner/Info.plist' 'psyche\.kelivo' 'com.psyche.jokelivo'
Replace-InFile 'ios/Runner/Info.plist' 'Kelivo 需要使用相机拍摄照片' 'JO-Kelivo 需要使用相机拍摄照片'
Replace-InFile 'ios/Runner/Info.plist' 'Kelivo uses the camera' 'JO-Kelivo uses the camera'
Replace-InFile 'ios/Runner.xcodeproj/project.pbxproj' 'psyche\.kelivo' 'com.psyche.jokelivo'
Replace-InFile 'ios/Runner.xcodeproj/project.pbxproj' 'com\.psyche\.kelivo' 'com.psyche.jokelivo'
Replace-InFile 'macos/Runner/Configs/AppInfo.xcconfig' 'PRODUCT_NAME = kelivo' 'PRODUCT_NAME = JO-Kelivo'
Replace-InFile 'macos/Runner/Configs/AppInfo.xcconfig' 'PRODUCT_BUNDLE_IDENTIFIER = com\.psyche\.kelivo' 'PRODUCT_BUNDLE_IDENTIFIER = com.psyche.jokelivo'
Replace-InFile 'macos/Runner.xcodeproj/project.pbxproj' 'kelivo\.app' 'JO-Kelivo.app'
Replace-InFile 'macos/Runner.xcodeproj/project.pbxproj' 'com\.psyche\.kelivo' 'com.psyche.jokelivo'
Replace-InFile 'macos/Runner.xcodeproj/project.pbxproj' 'psyche\.kelivo' 'com.psyche.jokelivo'
Replace-InFile 'macos/Runner.xcodeproj/project.pbxproj' 'TEST_HOST = "\$\(BUILT_PRODUCTS_DIR\)/kelivo\.app/\$\(BUNDLE_EXECUTABLE_FOLDER_PATH\)/kelivo";' 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/JO-Kelivo.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/JO-Kelivo";'
Replace-InFile 'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme' 'kelivo\.app' 'JO-Kelivo.app'

# Windows/Linux/Web identity
Replace-InFile 'windows/CMakeLists.txt' 'project\(kelivo LANGUAGES CXX\)' 'project(jo_kelivo LANGUAGES CXX)'
Replace-InFile 'windows/CMakeLists.txt' 'set\(BINARY_NAME "kelivo"\)' 'set(BINARY_NAME "jo_kelivo")'
Copy-Old 'windows/runner/main.cpp'
Copy-Old 'windows/runner/win32_window.cpp'
Copy-Old 'windows/runner/win32_window.h'
Replace-InFile 'windows/runner/Runner.rc' 'FileDescription", "kelivo' 'FileDescription", "JO-Kelivo'
Replace-InFile 'windows/runner/Runner.rc' 'InternalName", "kelivo' 'InternalName", "jo_kelivo'
Replace-InFile 'windows/runner/Runner.rc' 'OriginalFilename", "kelivo\.exe' 'OriginalFilename", "jo_kelivo.exe'
Replace-InFile 'windows/runner/Runner.rc' 'ProductName", "kelivo' 'ProductName", "JO-Kelivo'
Replace-InFile 'linux/CMakeLists.txt' 'set\(BINARY_NAME "kelivo"\)' 'set(BINARY_NAME "jo_kelivo")'
Replace-InFile 'linux/CMakeLists.txt' 'set\(APPLICATION_ID "com\.psyche\.kelivo"\)' 'set(APPLICATION_ID "com.psyche.jokelivo")'
Replace-InFile 'linux/runner/my_application.cc' 'gtk_window_set_icon_name\(window, "kelivo"\)' 'gtk_window_set_icon_name(window, "jo_kelivo")'
Replace-InFile 'linux/runner/my_application.cc' 'gtk_header_bar_set_title\(header_bar, "kelivo"\)' 'gtk_header_bar_set_title(header_bar, "JO-Kelivo")'
Replace-InFile 'linux/runner/my_application.cc' 'gtk_window_set_title\(window, "kelivo"\)' 'gtk_window_set_title(window, "JO-Kelivo")'
Replace-InFile 'web/manifest.json' '"name": "kelivo"' '"name": "JO-Kelivo"'
Replace-InFile 'web/manifest.json' '"short_name": "kelivo"' '"short_name": "JO-Kelivo"'
Replace-InFile 'web/index.html' 'apple-mobile-web-app-title" content="kelivo"' 'apple-mobile-web-app-title" content="JO-Kelivo"'
Replace-InFile 'web/index.html' '<title>kelivo</title>' '<title>JO-Kelivo</title>'

# Dart-visible app identity, tray and update source
Replace-InFile 'lib/main.dart' "initializeAndShow\(title: 'Kelivo'\)" "initializeAndShow(title: 'JO-Kelivo')"
Replace-InFile 'lib/main.dart' "title: 'Kelivo'" "title: 'JO-Kelivo'"
Replace-InFile 'lib/desktop/desktop_tray_controller.dart' "setToolTip\('Kelivo'\)" "setToolTip('JO-Kelivo')"
Copy-Old 'lib/core/providers/update_provider.dart'
Copy-Old 'test/update_provider_test.dart'

# Windows installer scripts from JO reference
Copy-Old 'scripts/windows'

# README and release/maintainer docs
Copy-Old 'README.md'
Copy-Old '维护者改版记录.md'
Copy-Old 'Release日志.md'
Replace-InFile 'README.md' '0\.1\.2\+2' '0.1.3+3'
Replace-InFile 'Release日志.md' '基于原版 Kelivo 的非官方修改版本' '基于原版 Kelivo 1.1.16 的非官方修改版本'

# Localized visible app brand keys in all ARBs
$arbFiles = @('lib/l10n/app_en.arb','lib/l10n/app_zh.arb','lib/l10n/app_zh_Hans.arb','lib/l10n/app_zh_Hant.arb')
foreach ($f in $arbFiles) {
  Replace-InFile $f '"aboutPageAppName":\s*"Kelivo"' '"aboutPageAppName": "JO-Kelivo"'
  Replace-InFile $f '"settingsShare":\s*"Kelivo - ([^"]+)"' '"settingsShare": "JO-Kelivo - $1"'
  Replace-InFile $f 'Kelivo is generating' 'JO-Kelivo is generating'
  Replace-InFile $f 'Kelivo 正在生成' 'JO-Kelivo 正在生成'
  Replace-InFile $f 'Kelivo is running' 'JO-Kelivo is running'
  Replace-InFile $f 'Kelivo 正在运行' 'JO-Kelivo 正在运行'
  Replace-InFile $f 'Kelivo 正在運行' 'JO-Kelivo 正在運行'
  Replace-InFile $f 'keep Kelivo running forever' 'keep JO-Kelivo running forever'
  Replace-InFile $f '保持 Kelivo 运行' '保持 JO-Kelivo 运行'
  Replace-InFile $f '保持 Kelivo 運行' '保持 JO-Kelivo 運行'
}
Replace-InFile 'lib/l10n/app_en.arb' '"aboutPageAppDescription":\s*"Open-source AI Assistant"' '"aboutPageAppDescription": "Open-source AI assistant based on Kelivo"'
Replace-InFile 'lib/l10n/app_zh.arb' '"aboutPageAppDescription":\s*"开源AI 助手"' '"aboutPageAppDescription": "基于 Kelivo 的开源 AI 助手"'
Replace-InFile 'lib/l10n/app_zh_Hans.arb' '"aboutPageAppDescription":\s*"开源 AI 助手"' '"aboutPageAppDescription": "基于 Kelivo 的开源 AI 助手"'
Replace-InFile 'lib/l10n/app_zh_Hant.arb' '"aboutPageAppDescription":\s*"開源 AI 助理"' '"aboutPageAppDescription": "基於 Kelivo 的開源 AI 助理"'

# Update provider test asset names to current release naming convention
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_android_0\.2\.0\+3_armeabi-v7a\.apk' 'JO-Kelivo-v0.2.0+3-android-armeabi-v7a-release.apk'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_android_0\.2\.0\+3_arm64-v8a\.apk' 'JO-Kelivo-v0.2.0+3-android-arm64-v8a-release.apk'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_windows_0\.2\.0\+3\.zip' 'JO-Kelivo-v0.2.0+3-windows-x64-portable.zip'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_windows_0\.2\.0\+3_setup\.exe' 'JO-Kelivo-v0.2.0+3-windows-x64-setup.exe'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_macos_0\.2\.0\+3\.dmg' 'JO-Kelivo-v0.2.0+3-macos-universal-dmg.dmg'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_linux_0\.2\.0\+3\.tar\.gz' 'JO-Kelivo-v0.2.0+3-linux-x64-tar.gz'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_linux_0\.2\.0\+3\.AppImage' 'JO-Kelivo-v0.2.0+3-linux-x64-appimage.AppImage'
Replace-InFile 'test/update_provider_test.dart' 'JO-Kelivo_android_0\.2\.0\+3_arm64-v8a\.apk\.sha256' 'JO-Kelivo-v0.2.0+3-android-arm64-v8a-release.apk.sha256'

Write-Host 'Identity patch complete.'
