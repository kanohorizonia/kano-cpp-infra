param(
  [Parameter(Mandatory = $true)]
  [string]$Action,

  [string]$Path = "",
  [string]$Root = "",
  [string]$BuildDir = "",
  [string]$Config = "Debug",
  [string]$Generator = "Ninja",
  [string]$Arch = "x64",
  [string]$CoverageBuildDir = "",
  [string]$Vcvars = "",
  [string]$ConfigurePreset = "",
  [string]$BuildPreset = "",
  [string]$VcvarsVersion = "14.44.35207"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Detect-VsDevCmd {
  $preferred = @(
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
  )
  foreach ($candidate in $preferred) {
    if (Test-Path -LiteralPath $candidate) {
      Write-Output $candidate
      return
    }
  }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path -LiteralPath $vswhere) {
    $found = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "Common7\Tools\VsDevCmd.bat" 2>$null |
      Select-Object -First 1
    if ($found) {
      Write-Output $found
      return
    }
  }

  $roots = @()
  if ($env:ProgramFiles) {
    $roots += (Join-Path $env:ProgramFiles "Microsoft Visual Studio")
  }
  if (${env:ProgramFiles(x86)}) {
    $roots += (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
  }

  $scan = Get-ChildItem -Path $roots -Recurse -File -Filter VsDevCmd.bat -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if ($scan) {
    Write-Output $scan
  }
}

function Detect-Vcvarsall {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path -LiteralPath $vswhere) {
    $found = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "VC\Auxiliary\Build\vcvarsall.bat" 2>$null |
      Select-Object -First 1
    if ($found) {
      Write-Output $found
      return
    }
  }

  $roots = @()
  if ($env:ProgramFiles) {
    $roots += (Join-Path $env:ProgramFiles "Microsoft Visual Studio")
  }
  if (${env:ProgramFiles(x86)}) {
    $roots += (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
  }

  $scan = Get-ChildItem -Path $roots -Recurse -File -Filter vcvarsall.bat -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\VC\\Auxiliary\\Build\\vcvarsall\.bat$" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if ($scan) {
    Write-Output $scan
  }
}

function Format-CMakeCacheArgument([string]$Name, [string]$Value) {
  $escapedValue = $Value.Replace('"', '""')
  return ('"-D{0}={1}"' -f $Name, $escapedValue)
}

function Get-AdditionalCMakeCacheArguments {
  $arguments = New-Object System.Collections.Generic.List[string]

  if (-not [string]::IsNullOrWhiteSpace($env:KOB_COMPILER_LAUNCHER)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "CMAKE_C_COMPILER_LAUNCHER" -Value $env:KOB_COMPILER_LAUNCHER))
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "CMAKE_CXX_COMPILER_LAUNCHER" -Value $env:KOB_COMPILER_LAUNCHER))
  }

  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_VERSION)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_VERSION_STR" -Value $env:KOB_BUILD_VERSION))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_BRANCH)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_BRANCH" -Value $env:KOB_BUILD_BRANCH))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_REVISION_HASH_SHORT)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_REVISION_HASH_SHORT" -Value $env:KOB_BUILD_REVISION_HASH_SHORT))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_REVISION_HASH)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_REVISION_HASH" -Value $env:KOB_BUILD_REVISION_HASH))
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_REVISION" -Value $env:KOB_BUILD_REVISION_HASH))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_DIRTY)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_DIRTY" -Value $env:KOB_BUILD_DIRTY))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_HOST_NAME)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_HOST_NAME" -Value $env:KOB_BUILD_HOST_NAME))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:KOB_BUILD_PLATFORM)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KB_BUILD_PLATFORM" -Value $env:KOB_BUILD_PLATFORM))
  }

  return $arguments.ToArray()
}

function Invoke-CmdChain([string]$CmdLine) {
  cmd.exe /d /s /c $CmdLine
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

function Run-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset) -or [string]::IsNullOrWhiteSpace($BuildPreset)) {
    throw "Root, ConfigurePreset, and BuildPreset are required"
  }

  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) {
    $resolvedVcvars = Detect-Vcvarsall
  }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) {
    throw "vcvarsall.bat not found"
  }

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) {
    $configureCommand += " " + $additionalArgument
  }

  $quotedVcvars = '"' + $resolvedVcvars + '"'
  Invoke-CmdChain ("call $quotedVcvars $Arch -vcvars_ver=$VcvarsVersion && $configureCommand")
  Invoke-CmdChain ("call $quotedVcvars $Arch -vcvars_ver=$VcvarsVersion && cmake --build --preset $BuildPreset")
}

function Configure-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset)) {
    throw "Root and ConfigurePreset are required"
  }

  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) {
    $resolvedVcvars = Detect-Vcvarsall
  }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) {
    throw "vcvarsall.bat not found"
  }

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) {
    $configureCommand += " " + $additionalArgument
  }

  $quotedVcvars = '"' + $resolvedVcvars + '"'
  Invoke-CmdChain ("call $quotedVcvars $Arch -vcvars_ver=$VcvarsVersion && $configureCommand")
}

function Run-Build {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($BuildDir)) {
    throw "Root and BuildDir are required"
  }

  $vsDevCmd = Detect-VsDevCmd
  if (-not $vsDevCmd) {
    throw "VsDevCmd.bat not found"
  }

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  $buildPath = Join-Path $rootPath $BuildDir
  New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

  $extraArgs = @()
  if ($env:KOB_COMPILER_LAUNCHER) {
    $launcher = $env:KOB_COMPILER_LAUNCHER
    $extraArgs += "-DCMAKE_C_COMPILER_LAUNCHER=$launcher"
    $extraArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER=$launcher"
  }

  if ($env:CMAKE_OSX_ARCHITECTURES) {
    $extraArgs += "-DCMAKE_OSX_ARCHITECTURES=$env:CMAKE_OSX_ARCHITECTURES"
  }

  $joinedExtraArgs = ""
  if ($extraArgs.Count -gt 0) {
    $joinedExtraArgs = " " + ($extraArgs -join " ")
  }

  $configure = "call `"$vsDevCmd`" -arch=$Arch -host_arch=$Arch && cmake -S `"$rootPath`" -B `"$buildPath`" -G `"$Generator`" -DCMAKE_BUILD_TYPE=$Config$joinedExtraArgs && cmake --build `"$buildPath`""
  cmd.exe /d /c $configure
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

function Run-Coverage-Build {
  if ([string]::IsNullOrWhiteSpace($Root)) {
    throw "Root is required for coverage build"
  }
  $coverageDir = $CoverageBuildDir
  if ([string]::IsNullOrWhiteSpace($coverageDir)) {
    $coverageDir = "build/_intermediate/windows-ninja-msvc-coverage"
  }

  $vsDevCmd = Detect-VsDevCmd
  if (-not $vsDevCmd) {
    throw "VsDevCmd.bat not found"
  }

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  $buildPath = Join-Path $rootPath $coverageDir
  New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

  $extraArgs = @(
    "-DKANO_ENABLE_COVERAGE=ON"
  )
  if ($env:KOB_COMPILER_LAUNCHER) {
    $extraArgs += "-DCMAKE_C_COMPILER_LAUNCHER=$env:KOB_COMPILER_LAUNCHER"
    $extraArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER=$env:KOB_COMPILER_LAUNCHER"
  }

  $joinedExtraArgs = " " + ($extraArgs -join " ")

  $configure = "call `"$vsDevCmd`" -arch=$Arch -host_arch=$Arch && cmake -S `"$rootPath`" -B `"$buildPath`" -G `"$Generator`" -DCMAKE_BUILD_TYPE=Debug$joinedExtraArgs && cmake --build `"$buildPath`""
  cmd.exe /d /c $configure
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

switch ($Action) {
  "test-path" {
    if (Test-Path -LiteralPath $Path) { exit 0 } else { exit 1 }
  }
  "detect-vcvarsall" { Detect-Vcvarsall }
  "detect-vsdevcmd" { Detect-VsDevCmd }
  "run-build" { Run-Build }
  "run-preset" { Run-Preset }
  "configure-preset" { Configure-Preset }
  "run-coverage-build" { Run-Coverage-Build }
  default { throw "Unknown action: $Action" }
}
