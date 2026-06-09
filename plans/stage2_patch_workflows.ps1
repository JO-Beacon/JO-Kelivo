$ErrorActionPreference = 'Stop'

$workflowFiles = Get-ChildItem -Path '.github/workflows' -File | Where-Object { $_.Extension -in @('.yml', '.yaml') }

foreach ($file in $workflowFiles) {
  $path = $file.FullName
  $text = [System.IO.File]::ReadAllText($path)

  $text = $text.Replace('Kelivo_android_${VERSION}_${abi}.apk', 'JO-Kelivo-v${VERSION}-android-${abi}-release.apk')
  $text = $text.Replace('Kelivo_android_*_arm64-v8a.apk', 'JO-Kelivo-v*-android-arm64-v8a-release.apk')
  $text = $text.Replace('Kelivo_android_*_armeabi-v7a.apk', 'JO-Kelivo-v*-android-armeabi-v7a-release.apk')
  $text = $text.Replace('Kelivo_android_*_x86_64.apk', 'JO-Kelivo-v*-android-x86_64-release.apk')
  $text = $text.Replace('Kelivo_android_*.apk', 'JO-Kelivo-v*-android-*-release.apk')

  $text = $text.Replace('Kelivo_ios_${VERSION}.ipa', 'JO-Kelivo-v${VERSION}-ios-universal-release.ipa')
  $text = $text.Replace('Kelivo_ios_*.ipa', 'JO-Kelivo-v*-ios-universal-release.ipa')

  $text = $text.Replace('--volname "Kelivo"', '--volname "JO-Kelivo"')
  $text = $text.Replace('hdiutil create -volname Kelivo', 'hdiutil create -volname JO-Kelivo')
  $text = $text.Replace('build/macos/Build/Products/Release/kelivo.app', 'build/macos/Build/Products/Release/JO-Kelivo.app')
  $text = $text.Replace('Kelivo_macos_${VERSION}.dmg', 'JO-Kelivo-v${VERSION}-macos-universal-dmg.dmg')
  $text = $text.Replace('Kelivo_macos_*.dmg', 'JO-Kelivo-v*-macos-universal-dmg.dmg')

  $text = $text.Replace('Kelivo_windows_$env:VERSION.zip', 'JO-Kelivo-v$env:VERSION-windows-x64-portable.zip')
  $text = $text.Replace('Kelivo_windows_*_setup.exe', 'JO-Kelivo-v*-windows-x64-setup.exe')
  $text = $text.Replace('Kelivo_windows_*.zip', 'JO-Kelivo-v*-windows-x64-portable.zip')
  $text = $text.Replace('#define MyAppName "Kelivo"', '#define MyAppName "JO-Kelivo"')
  $text = $text.Replace('#define MyAppExeName "kelivo.exe"', '#define MyAppExeName "jo_kelivo.exe"')
  $text = $text.Replace('OutputBaseFilename=Kelivo_windows_{#MyAppVersion}_setup', 'OutputBaseFilename=JO-Kelivo-v{#MyAppVersion}-windows-x64-setup')

  $text = $text.Replace('Kelivo_linux_${VERSION}_arm64.tar.gz', 'JO-Kelivo-v${VERSION}-linux-arm64-tar.gz')
  $text = $text.Replace('Kelivo_linux_${VERSION}_arm64.AppImage', 'JO-Kelivo-v${VERSION}-linux-arm64-appimage.AppImage')
  $text = $text.Replace('Kelivo_linux_${VERSION}_arm64.deb', 'JO-Kelivo-v${VERSION}-linux-arm64-deb.deb')
  $text = $text.Replace('Kelivo_linux_${VERSION}_arm64.rpm', 'JO-Kelivo-v${VERSION}-linux-arm64-rpm.rpm')
  $text = $text.Replace('Kelivo_linux_*_arm64.tar.gz', 'JO-Kelivo-v*-linux-arm64-tar.gz')
  $text = $text.Replace('Kelivo_linux_*_arm64.AppImage', 'JO-Kelivo-v*-linux-arm64-appimage.AppImage')
  $text = $text.Replace('Kelivo_linux_*_arm64.deb', 'JO-Kelivo-v*-linux-arm64-deb.deb')
  $text = $text.Replace('Kelivo_linux_*_arm64.rpm', 'JO-Kelivo-v*-linux-arm64-rpm.rpm')
  $text = $text.Replace('Kelivo_linux_${VERSION}.tar.gz', 'JO-Kelivo-v${VERSION}-linux-x64-tar.gz')
  $text = $text.Replace('Kelivo_linux_${VERSION}.AppImage', 'JO-Kelivo-v${VERSION}-linux-x64-appimage.AppImage')
  $text = $text.Replace('Kelivo_linux_${VERSION}_amd64.deb', 'JO-Kelivo-v${VERSION}-linux-x64-deb.deb')
  $text = $text.Replace('Kelivo_linux_${VERSION}.rpm', 'JO-Kelivo-v${VERSION}-linux-x64-rpm.rpm')
  $text = $text.Replace('Kelivo_linux_*.tar.gz', 'JO-Kelivo-v*-linux-x64-tar.gz')
  $text = $text.Replace('Kelivo_linux_*.AppImage', 'JO-Kelivo-v*-linux-x64-appimage.AppImage')
  $text = $text.Replace('Kelivo_linux_*_amd64.deb', 'JO-Kelivo-v*-linux-x64-deb.deb')
  $text = $text.Replace('Kelivo_linux_*.rpm', 'JO-Kelivo-v*-linux-x64-rpm.rpm')

  $text = $text.Replace('Name=Kelivo', 'Name=JO-Kelivo')
  $text = $text.Replace('Exec=kelivo', 'Exec=jo_kelivo')
  $text = $text.Replace('Icon=kelivo', 'Icon=jo_kelivo')
  $text = $text.Replace('exec "${HERE}/usr/bin/kelivo" "$@"', 'exec "${HERE}/usr/bin/jo_kelivo" "$@"')
  $text = $text.Replace('AppDir/kelivo.desktop', 'AppDir/jo_kelivo.desktop')
  $text = $text.Replace('linux/kelivo.png', 'linux/jo_kelivo.png')
  $text = $text.Replace('AppDir/kelivo.png', 'AppDir/jo_kelivo.png')
  $text = $text.Replace('apps/kelivo.png', 'apps/jo_kelivo.png')
  $text = $text.Replace('mkdir -p deb/opt/kelivo', 'mkdir -p deb/opt/jo_kelivo')
  $text = $text.Replace('deb/opt/kelivo/', 'deb/opt/jo_kelivo/')
  $text = $text.Replace('deb/opt/kelivo/kelivo.sh', 'deb/opt/jo_kelivo/jo_kelivo.sh')
  $text = $text.Replace('cd "$(dirname "$0")"' + "`n" + '          ./kelivo "$@"', 'cd "$(dirname "$0")"' + "`n" + '          ./jo_kelivo "$@"')
  $text = $text.Replace('ln -s /opt/kelivo/kelivo deb/usr/bin/kelivo', 'ln -s /opt/jo_kelivo/jo_kelivo deb/usr/bin/jo_kelivo')
  $text = $text.Replace('Exec=/opt/kelivo/kelivo', 'Exec=/opt/jo_kelivo/jo_kelivo')
  $text = $text.Replace('Package: kelivo', 'Package: jo-kelivo')
  $text = $text.Replace('Description: Kelivo Application', 'Description: JO-Kelivo Application')
  $text = $text.Replace('mkdir -p kelivo-${VERSION_NUMBER}', 'mkdir -p jo-kelivo-${VERSION_NUMBER}')
  $text = $text.Replace('kelivo-${VERSION_NUMBER}', 'jo-kelivo-${VERSION_NUMBER}')
  $text = $text.Replace('~/rpmbuild/SPECS/kelivo.spec', '~/rpmbuild/SPECS/jo-kelivo.spec')
  $text = $text.Replace('Name:           kelivo', 'Name:           jo-kelivo')
  $text = $text.Replace('Summary:        Kelivo Application', 'Summary:        JO-Kelivo Application')
  $text = $text.Replace('/opt/kelivo', '/opt/jo_kelivo')
  $text = $text.Replace('/usr/bin/kelivo', '/usr/bin/jo_kelivo')
  $text = $text.Replace('kelivo.desktop', 'jo_kelivo.desktop')
  $text = $text.Replace('cp kelivo.png', 'cp jo_kelivo.png')
  $text = $text.Replace('rpmbuild/SPECS/kelivo.spec', 'rpmbuild/SPECS/jo-kelivo.spec')

  [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
  Write-Host "patched $($file.Name)"
}
