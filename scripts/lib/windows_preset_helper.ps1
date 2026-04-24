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
  [string]$VcvarsVersion = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($VcvarsVersion)) {
  $VcvarsVersion = $env:KANO_VCVARS_VERSION
}
if ([string]::IsNullOrWhiteSpace($VcvarsVersion)) {
  $VcvarsVersion = "14.44.35207"
}

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
  if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles "Microsoft Visual Studio") }
  if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio") }

  $scan = Get-ChildItem -Path $roots -Recurse -File -Filter VsDevCmd.bat -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if ($scan) { Write-Output $scan }
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
  if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles "Microsoft Visual Studio") }
  if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio") }

  $scan = Get-ChildItem -Path $roots -Recurse -File -Filter vcvarsall.bat -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\VC\\Auxiliary\\Build\\vcvarsall\.bat$" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if ($scan) { Write-Output $scan }
}

function Format-CMakeCacheArgument([string]$Name, [string]$Value) {
  $escapedValue = $Value.Replace('"', '""')
  return ('"-D{0}={1}"' -f $Name, $escapedValue)
}

function Get-AdditionalCMakeCacheArguments {
  $arguments = New-Object System.Collections.Generic.List[string]

  $buildPrefix = $env:KABSD_BUILD_PREFIX
  if ([string]::IsNullOrWhiteSpace($buildPrefix)) {
    $buildPrefix = "KOB"
  }

  $launcher = [Environment]::GetEnvironmentVariable("KOG_COMPILER_LAUNCHER")
  if ([string]::IsNullOrWhiteSpace($launcher)) {
    $launcher = [Environment]::GetEnvironmentVariable("${buildPrefix}_COMPILER_LAUNCHER")
  }
  
  if (-not [string]::IsNullOrWhiteSpace($launcher)) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "CMAKE_C_COMPILER_LAUNCHER" -Value $launcher))
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "CMAKE_CXX_COMPILER_LAUNCHER" -Value $launcher))
  }

  $cmakeVarPrefix = $env:KABSD_CMAKE_VAR_PREFIX
  if ([string]::IsNullOrWhiteSpace($cmakeVarPrefix)) {
    $cmakeVarPrefix = "KB"
  }

  $valueMap = @{
    "VERSION_STR" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_VERSION")
    "BUILD_BRANCH" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_BRANCH")
    "BUILD_REVISION_HASH_SHORT" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_REVISION_HASH_SHORT")
    "BUILD_REVISION_HASH" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_REVISION_HASH")
    "BUILD_DIRTY" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_DIRTY")
    "BUILD_HOST_NAME" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_HOST_NAME")
    "BUILD_PLATFORM" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_PLATFORM")
  }

  if (-not [string]::IsNullOrWhiteSpace($valueMap["VERSION_STR"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_VERSION_STR" -Value $valueMap["VERSION_STR"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_BRANCH"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_BRANCH" -Value $valueMap["BUILD_BRANCH"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_REVISION_HASH_SHORT"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_REVISION_HASH_SHORT" -Value $valueMap["BUILD_REVISION_HASH_SHORT"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_REVISION_HASH"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_REVISION_HASH" -Value $valueMap["BUILD_REVISION_HASH"]))
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_REVISION" -Value $valueMap["BUILD_REVISION_HASH"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_DIRTY"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_DIRTY" -Value $valueMap["BUILD_DIRTY"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_HOST_NAME"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_HOST_NAME" -Value $valueMap["BUILD_HOST_NAME"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_PLATFORM"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_PLATFORM" -Value $valueMap["BUILD_PLATFORM"]))
  }

  return $arguments.ToArray()
}

function Get-PixiEnvironmentRoot([string]$ProjectRoot) {
  # First check for infra pixi at the standard shared-infra location
  $infraPixiRoot = Join-Path $ProjectRoot "shared\infra\.pixi\envs\default"
  if (Test-Path -LiteralPath $infraPixiRoot) {
    return (Resolve-Path -LiteralPath $infraPixiRoot).Path
  }

  # Fall back to walking up from ProjectRoot
  $root = $ProjectRoot
  while (-not [string]::IsNullOrWhiteSpace($root)) {
    $pixiEnvRoot = Join-Path $root ".pixi\envs\default"
    if (Test-Path -LiteralPath $pixiEnvRoot) {
      return (Resolve-Path -LiteralPath $pixiEnvRoot).Path
    }
    $parentRoot = Split-Path -Parent $root
    if ([string]::IsNullOrWhiteSpace($parentRoot) -or $parentRoot -eq $root) {
      break
    }
    $root = $parentRoot
  }

  throw "pixi environment root not found from $ProjectRoot. Run './kog self install-prereq'."
}

function Get-PixiBuildToolPrefix([string]$ProjectRoot) {
  $pixiEnvRoot = Get-PixiEnvironmentRoot -ProjectRoot $ProjectRoot
  $candidates = @(
    (Join-Path $pixiEnvRoot "Library\bin"),
    (Join-Path $pixiEnvRoot "Scripts"),
    (Join-Path $pixiEnvRoot "bin")
  )

  $resolved = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      [void]$resolved.Add((Resolve-Path -LiteralPath $candidate).Path)
    }
  }

  if ($resolved.Count -eq 0) {
    throw "pixi build tool environment not found under $pixiEnvRoot. Run './kog self install-prereq'."
  }

  return [string]::Join(';', $resolved)
}

function Get-PixiNinjaPath([string]$ProjectRoot) {
  $pixiEnvRoot = Get-PixiEnvironmentRoot -ProjectRoot $ProjectRoot
  $ninjaPath = Join-Path $pixiEnvRoot "Library\bin\ninja.exe"
  if (-not (Test-Path -LiteralPath $ninjaPath)) {
    throw "pixi ninja.exe not found at $ninjaPath. Run './kog self install-prereq'."
  }
  return (Resolve-Path -LiteralPath $ninjaPath).Path
}

function Invoke-CmdChain([string]$CmdLine) {
  cmd.exe /d /s /c $CmdLine
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Run-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset) -or [string]::IsNullOrWhiteSpace($BuildPreset)) {
    throw "Root, ConfigurePreset, and BuildPreset are required"
  }
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath
  $pixiPathPrefix = Get-PixiBuildToolPrefix -ProjectRoot $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) { $configureCommand += " " + $additionalArgument }

  $vcvarsCommand = ('call "{0}" {1} -vcvars_ver={2}' -f $resolvedVcvars, $Arch, $VcvarsVersion)
  Invoke-CmdChain ('{0} && set "PATH={1};%PATH%" && {2}' -f $vcvarsCommand, $pixiPathPrefix, $configureCommand)
  Invoke-CmdChain ('{0} && set "PATH={1};%PATH%" && cmake --build --preset {2}' -f $vcvarsCommand, $pixiPathPrefix, $BuildPreset)
}

function Configure-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset)) {
    throw "Root and ConfigurePreset are required"
  }
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath
  $pixiPathPrefix = Get-PixiBuildToolPrefix -ProjectRoot $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) { $configureCommand += " " + $additionalArgument }

  $vcvarsCommand = ('call "{0}" {1} -vcvars_ver={2}' -f $resolvedVcvars, $Arch, $VcvarsVersion)
  Invoke-CmdChain ('{0} && set "PATH={1};%PATH%" && {2}' -f $vcvarsCommand, $pixiPathPrefix, $configureCommand)
}

switch ($Action) {
  "test-path" { if (Test-Path -LiteralPath $Path) { exit 0 } else { exit 1 } }
  "detect-vcvarsall" { Detect-Vcvarsall }
  "detect-vsdevcmd" { Detect-VsDevCmd }
  "run-preset" { Run-Preset }
  "configure-preset" { Configure-Preset }
  default { throw "Unknown action: $Action" }
}
