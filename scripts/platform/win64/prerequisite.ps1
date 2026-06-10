#!/usr/bin/env bash
set -euo pipefail

if ! command -v powershell >/dev/null 2>&1; then
  echo "powershell is required." >&2
  exit 1
fi

powershell -NoProfile -ExecutionPolicy Bypass -Command - <<'POWERSHELL'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

try {

function Write-LauncherStatus {
  param(
    [string]$Step,
    [string]$Status,
    [string]$Message = ''
  )

  if ([string]::IsNullOrWhiteSpace($Message)) {
    Write-Host "[launcher][$Step][$Status]"
    return
  }

  Write-Host "[launcher][$Step][$Status] $Message"
}

function Invoke-LauncherStep {
  param(
    [string]$Step,
    [scriptblock]$Action
  )

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Write-LauncherStatus -Step $Step -Status 'start'
  try {
    & $Action
    $sw.Stop()
    Write-LauncherStatus -Step $Step -Status 'ok' -Message "elapsed=$([int]$sw.Elapsed.TotalSeconds)s"
  } catch {
    $sw.Stop()
    $msg = $_.Exception.Message
    Write-LauncherStatus -Step $Step -Status 'fail' -Message "elapsed=$([int]$sw.Elapsed.TotalSeconds)s error=$msg"
    throw
  }
}

function Ensure-WingetPackage {
  param([string]$Id)

  Invoke-LauncherStep -Step "prereq:$Id" -Action {
    $noUpgradeCode = -1978335189
    $installerBusyCode = -1978334974
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-LauncherStatus -Step "prereq:$Id" -Status 'info' -Message 'mode=install'
      winget install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
      if ($LASTEXITCODE -ne 0) {
        if ($LASTEXITCODE -eq $installerBusyCode -or $LASTEXITCODE -eq 1618) {
          throw "installer busy (exit 1618) while installing $Id. Another installation is in progress; wait and retry."
        }
        throw "winget install failed for $Id with exit code $LASTEXITCODE"
      }
      return
    }

    Write-LauncherStatus -Step "prereq:$Id" -Status 'info' -Message 'mode=upgrade'
    winget upgrade --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $noUpgradeCode) {
      throw "winget upgrade failed for $Id with exit code $LASTEXITCODE"
    }
  }
}

function Get-PixiEnvironmentRoot {
  if (-not [string]::IsNullOrWhiteSpace($env:PIXI_PROJECT_ROOT)) {
    return $env:PIXI_PROJECT_ROOT
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CONDA_PREFIX)) {
    return $env:CONDA_PREFIX
  }
  return $null
}

function Test-CommandAvailable {
  param([string[]]$Names)

  foreach ($name in $Names) {
    if ([string]::IsNullOrWhiteSpace($name)) {
      continue
    }
    if (Get-Command $name -ErrorAction SilentlyContinue) {
      return $true
    }
  }

  return $false
}

function Ensure-WingetPackageUnlessCommandAvailable {
  param(
    [string]$Id,
    [string[]]$CommandNames
  )

  $pixiRoot = Get-PixiEnvironmentRoot
  if ($pixiRoot -and (Test-CommandAvailable -Names $CommandNames)) {
    $commandLabel = ($CommandNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ','
    Write-LauncherStatus -Step "prereq:$Id" -Status 'info' -Message "mode=skip-pixi-env root=$pixiRoot commands=$commandLabel"
    return
  }

  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required to install $Id automatically. Install App Installer from Microsoft Store, or provide the tool via pixi/system PATH."
  }

  Ensure-WingetPackage -Id $Id
}

function Resolve-VcvarsallPath {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) {
    return $null
  }

  $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Auxiliary\Build\vcvarsall.bat' 2>$null | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($path)) {
    return $null
  }
  return $path
}

function Resolve-BuildToolsInstallPath {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) {
    return $null
  }

  $path = & $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($path)) {
    return $null
  }
  return $path
}

function Invoke-VsBuildToolsModify {
  param(
    [string]$InstallPath,
    [string[]]$ComponentIds
  )

  $setupExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
  if (-not (Test-Path $setupExe)) {
    throw 'Visual Studio installer (setup.exe) not found.'
  }

  if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    throw 'Unable to resolve existing Visual Studio Build Tools install path for component repair.'
  }

  $args = @('modify', '--installPath', $InstallPath, '--quiet', '--wait', '--norestart', '--nocache')
  foreach ($component in $ComponentIds) {
    $args += @('--add', $component)
  }

  Write-LauncherStatus -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Status 'info' -Message "mode=modify-existing installPath=$InstallPath"
  $proc = Start-Process -FilePath $setupExe -ArgumentList $args -Wait -PassThru -NoNewWindow

  if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "Visual Studio installer modify failed with exit code $($proc.ExitCode)"
  }
}

function Test-WindowsSdkToolsInstalled {
  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  if (-not (Test-Path $kitsRoot)) {
    return $false
  }

  $sdkBins = Get-ChildItem -Path $kitsRoot -Directory -ErrorAction SilentlyContinue
  foreach ($sdkBin in $sdkBins) {
    $x64Dir = Join-Path $sdkBin.FullName 'x64'
    if (-not (Test-Path $x64Dir)) {
      continue
    }

    $rc = Join-Path $x64Dir 'rc.exe'
    $mt = Join-Path $x64Dir 'mt.exe'
    if ((Test-Path $rc) -and (Test-Path $mt)) {
      return $true
    }
  }

  return $false
}

Write-LauncherStatus -Step 'prerequisite' -Status 'start' -Message 'windows dependency bootstrap'

Ensure-WingetPackageUnlessCommandAvailable -Id 'Kitware.CMake' -CommandNames @('cmake')
Ensure-WingetPackageUnlessCommandAvailable -Id 'Ninja-build.Ninja' -CommandNames @('ninja')

Invoke-LauncherStep -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Action {
  $installerBusyCode = -1978334974
  $componentIds = @(
    'Microsoft.VisualStudio.Workload.VCTools',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    'Microsoft.VisualStudio.Component.VC.CMake.Project',
    'Microsoft.VisualStudio.Component.Windows10SDK.19041'
  )

  $existingVcvarsall = Resolve-VcvarsallPath
  $sdkReady = Test-WindowsSdkToolsInstalled
  if ($existingVcvarsall -and $sdkReady) {
    Write-LauncherStatus -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Status 'info' -Message "mode=skip-existing-msvc vcvarsall=$existingVcvarsall sdk=ok"
    return
  }

  if ($existingVcvarsall -and -not $sdkReady) {
    Write-LauncherStatus -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Status 'info' -Message "mode=install-components reason=windows-sdk-missing vcvarsall=$existingVcvarsall"
  }

  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required to auto-install Microsoft.VisualStudio.2022.BuildTools. Please install App Installer from Microsoft Store.'
  }

  $maxBusyRetries = 6
  $busyRetryDelaySec = 20
  $wingetOverride = '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --add Microsoft.VisualStudio.Component.VC.CMake.Project --add Microsoft.VisualStudio.Component.Windows10SDK.19041'

  for ($attempt = 1; $attempt -le $maxBusyRetries; $attempt++) {
    Write-LauncherStatus -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Status 'info' -Message "mode=install-components attempt=$attempt/$maxBusyRetries"
    winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --override $wingetOverride --accept-source-agreements --accept-package-agreements --disable-interactivity

    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
      $existingVcvarsall = Resolve-VcvarsallPath
      $sdkReady = Test-WindowsSdkToolsInstalled
      if ($existingVcvarsall -and $sdkReady) {
        return
      }
      Write-LauncherStatus -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Status 'info' -Message 'winget completed but required components still missing; trying modify-existing repair'
      break
    }

    if (($LASTEXITCODE -eq $installerBusyCode -or $LASTEXITCODE -eq 1618) -and $attempt -lt $maxBusyRetries) {
      Write-LauncherStatus -Step 'prereq:Microsoft.VisualStudio.2022.BuildTools' -Status 'info' -Message "installer-busy retry-in=${busyRetryDelaySec}s"
      Start-Sleep -Seconds $busyRetryDelaySec
      continue
    }

    if ($LASTEXITCODE -eq $installerBusyCode -or $LASTEXITCODE -eq 1618) {
      throw 'installer busy (exit 1618) while installing Microsoft.VisualStudio.2022.BuildTools. Another installation is in progress; wait and retry.'
    }
    throw "winget install failed for Microsoft.VisualStudio.2022.BuildTools with exit code $LASTEXITCODE"
  }

  $installPath = Resolve-BuildToolsInstallPath
  Invoke-VsBuildToolsModify -InstallPath $installPath -ComponentIds $componentIds

  $existingVcvarsall = Resolve-VcvarsallPath
  $sdkReady = Test-WindowsSdkToolsInstalled
  if (-not $existingVcvarsall -or -not $sdkReady) {
    throw 'Build Tools install completed but required components are still missing (vcvarsall/Windows SDK).'
  }
}

Write-LauncherStatus -Step 'prerequisite' -Status 'ok' -Message 'windows dependency bootstrap complete'
} catch {
  Write-Error $_
  exit 1
}
POWERSHELL
