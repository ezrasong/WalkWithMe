param([string]$SdkRoot = "$env:USERPROFILE\.cache\kaze-android-sdk")
$ErrorActionPreference = 'Stop'
$kazeSdkRoot = [System.IO.Path]::GetFullPath($SdkRoot)
$commandTools = Join-Path $kazeSdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path -LiteralPath $commandTools)) {
    New-Item -ItemType Directory -Force -Path $kazeSdkRoot | Out-Null
    $archivePath = Join-Path $kazeSdkRoot 'commandlinetools.zip'
    $extractPath = Join-Path $kazeSdkRoot 'download'
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip' -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $kazeSdkRoot 'cmdline-tools') | Out-Null
    Move-Item -LiteralPath (Join-Path $extractPath 'cmdline-tools') -Destination (Join-Path $kazeSdkRoot 'cmdline-tools\latest')
}
Write-Output 'Review the Android SDK license if prompted. Type y to accept.'
& $commandTools "--sdk_root=$kazeSdkRoot" 'platforms;android-35' 'build-tools;35.0.0' 'platform-tools'
if ($LASTEXITCODE -ne 0) { throw 'Android SDK installation failed' }
$propertiesPath = Join-Path $PSScriptRoot '..\android\local.properties'
('sdk.dir=' + $kazeSdkRoot.Replace('\','/')) | Set-Content -LiteralPath $propertiesPath -Encoding utf8
Write-Output "SDK ready at $kazeSdkRoot"
