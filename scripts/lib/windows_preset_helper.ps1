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
  # Default to 2026 MSVC toolchain (14.44.35207)
  $VcvarsVersion = "14.44.35207"
}

function Detect-VsDevCmd {
  # Use vswhere to discover all installed Visual Studio instances with C++ toolset,
  # then select the newest version (VS2026/18 > VS2022/17).
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) {
    return $null
  }

  $allVsdev = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "Common7\Tools\VsDevCmd.bat" 2>$null

  if (-not $allVsdev -or $allVsdev.Count -eq 0) {
    return $null
  }

  # Parse VS version and sort descending (newest first)
  # VS2026/18 uses folder "2026" or "18", VS2022/17 uses "2022" or "17"
  # Two-digit versions (18, 17) represent VS2026/VS2022 and should sort above four-digit (2022, 2019)
  $sorted = $allVsdev | ForEach-Object {
    $path = $_
    if ($path -match 'Visual Studio\\([^\\]+)\\') {
      $versionStr = $matches[1]
      $sortKey = if ($versionStr -match '^\d+$') {
        if ([int]$versionStr -lt 100) { [int]$versionStr * 1000 } else { [int]$versionStr }
      } else { 0 }
      [PSCustomObject]@{ Path = $path; VersionStr = $versionStr; SortKey = $sortKey }
    } else {
      [PSCustomObject]@{ Path = $path; VersionStr = "0"; SortKey = 0 }
    }
  } | Sort-Object -Property SortKey -Descending

  $selected = $sorted | Select-Object -First 1
  if ($selected) { Write-Output $selected.Path }
}

function Detect-Vcvarsall {
  # Use vswhere to discover all installed Visual Studio instances with C++ toolset,
  # then select the newest version (VS2026/18 > VS2022/17).
  # vswhere is the canonical way to find VS installations regardless of install path.
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "vswhere.exe not found at '$vswhere'. Please repair Visual Studio installation."
  }

  # Find all VS installations with C++ toolset, return full path to vcvarsall.bat
  # Wrap in @() to ensure array even when vswhere returns a single string
  $allVcvars = @(& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "VC\Auxiliary\Build\vcvarsall.bat" 2>$null)

  if (-not $allVcvars -or $allVcvars.Count -eq 0) {
    throw "No Visual Studio installation with C++ toolset found. Please install Visual Studio with C++ workload."
  }

  # Parse VS version from installation path and sort descending (newest first)
  # VS2026/18 uses folder "2026" or "18", VS2022/17 uses "2022" or "17"
  # Two-digit versions (18, 17) represent VS2026/VS2022 and should sort above four-digit (2022, 2019)
  $sorted = $allVcvars | ForEach-Object {
    $path = $_
    # Extract version folder name (last path component before Community/Professional/Enterprise)
    if ($path -match 'Visual Studio\\([^\\]+)\\') {
      $versionStr = $matches[1]
      # Convert to sortable number: "2026" -> 2026, "18" -> 18000 (treat 2-digit as VS2026+)
      $sortKey = if ($versionStr -match '^\d+$') {
        if ([int]$versionStr -lt 100) { [int]$versionStr * 1000 } else { [int]$versionStr }
      } else { 0 }
      [PSCustomObject]@{
        Path = $path
        VersionStr = $versionStr
        SortKey = $sortKey
      }
    } else {
      [PSCustomObject]@{ Path = $path; VersionStr = "0"; SortKey = 0 }
    }
  } | Sort-Object -Property SortKey -Descending

  # Return the newest VS installation's vcvarsall.bat
  $selected = $sorted | Select-Object -First 1
  Write-Output $selected.Path
}

function Format-CMakeCacheArgument([string]$Name, [string]$Value) {
  $escapedValue = $Value.Replace('"', '""')
  return ('"-D{0}={1}"' -f $Name, $escapedValue)
}

function Get-AdditionalCMakeCacheArguments {
  $arguments = New-Object System.Collections.Generic.List[string]
  $buildPrefix = "KANO"
  $cmakeVarPrefix = "KANO"

  $valueMap = @{
    "VERSION_STR" = [Environment]::GetEnvironmentVariable("${buildPrefix}_VERSION_STR")
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
  # Check for infra-level pixi env first (src/cpp/shared/infra/.pixi/envs/default)
  # This takes priority over root-level .pixi since infra has its own environment
  $infraPixiRoot = Join-Path $ProjectRoot "shared\infra\.pixi\envs\default"
  if (Test-Path -LiteralPath $infraPixiRoot) {
    return (Resolve-Path -LiteralPath $infraPixiRoot).Path
  }

  # Fall back to root-level .pixi/envs/default
  $rootPixiEnvRoot = Join-Path $ProjectRoot ".pixi\envs\default"
  if (Test-Path -LiteralPath $rootPixiEnvRoot) {
    return (Resolve-Path -LiteralPath $rootPixiEnvRoot).Path
  }

  # Search up the tree for any .pixi/envs/default
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

function Test-ValidExecutable([string]$Path) {
  # Returns true only if the path points to a non-empty, valid executable file.
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $resolved) { return $false }
  $item = Get-Item -LiteralPath $resolved.Path -ErrorAction SilentlyContinue
  if (-not $item) { return $false }
  # Must be a file with non-zero length (WinGet symlinks can be 0-byte stubs)
  return ($item.Length -gt 0)
}

function Get-GlobalToolPath([string]$ToolName) {
  # Check common global pixi locations first — these are always valid executables.
  # This avoids picking up broken WinGet 0-byte stub symlinks from PATH.
  $userPixiBin = $null
  if ($env:HOME) {
    $userPixiBin = Join-Path $env:HOME ".pixi\bin"
  } elseif ($env:USERPROFILE) {
    $userPixiBin = Join-Path $env:USERPROFILE ".pixi\bin"
  }
  if ($userPixiBin) {
    $pixiToolPath = Join-Path $userPixiBin "$ToolName.exe"
    if (Test-ValidExecutable $pixiToolPath) {
      return (Resolve-Path -LiteralPath $pixiToolPath).Path
    }
    $pixiToolPathNoExt = Join-Path $userPixiBin $ToolName
    if (Test-ValidExecutable $pixiToolPathNoExt) {
      return (Resolve-Path -LiteralPath $pixiToolPathNoExt).Path
    }
  }

  # Try PowerShell-native PATH search, but validate the result is a real executable.
  $candidates = @(Get-Command -Name $ToolName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
  foreach ($candidate in $candidates) {
    if (Test-ValidExecutable $candidate) {
      return (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue).Path
    }
  }

  # Fallback to cmd.exe where, validating each result.
  $output = cmd.exe /c "where $ToolName 2>nul"
  if ($null -ne $output -and $output.Trim() -ne "") {
    foreach ($line in $output.Trim().Split([Environment]::NewLine)) {
      $toolPath = $line.Trim()
      if (Test-ValidExecutable $toolPath) {
        return (Resolve-Path -LiteralPath $toolPath).Path
      }
    }
  }

  return $null
}

function Get-PixiBuildToolPrefix([string]$ProjectRoot) {
  # First check for global tools (cmake, ninja) in PATH - these may come from ~/.pixi
  $cmakePath = Get-GlobalToolPath "cmake"
  $ninjaPath = Get-GlobalToolPath "ninja"
  $resolved = New-Object System.Collections.Generic.List[string]
  
  if ($cmakePath -and $ninjaPath) {
    $cmakeDir = Split-Path -Parent $cmakePath
    if ($cmakeDir) {
      [void]$resolved.Add($cmakeDir)
    }
  }

  # If global tools found, return them (allow pixi env to be missing)
  if ($resolved.Count -gt 0) {
    return [string]::Join(';', $resolved)
  }

  # Fall back to pixi environment
  $pixiEnvRoot = $null
  $pixiEnvFound = $false
  try {
    $pixiEnvRoot = Get-PixiEnvironmentRoot -ProjectRoot $ProjectRoot
    $pixiEnvFound = $true
  } catch {
    # No pixi environment found — will use global tools only
  }

  if ($pixiEnvFound -and $pixiEnvRoot) {
    $candidates = @(
      (Join-Path $pixiEnvRoot "Library\bin"),
      (Join-Path $pixiEnvRoot "Scripts"),
      (Join-Path $pixiEnvRoot "bin")
    )
    foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate) {
        [void]$resolved.Add((Resolve-Path -LiteralPath $candidate).Path)
      }
    }
  }

  if ($resolved.Count -eq 0) {
    if ($pixiEnvRoot) {
      throw "pixi build tool environment not found under $pixiEnvRoot. Run './kog self install-prereq'."
    } else {
      throw "pixi build tool environment not found. Run './kog self install-prereq' to install."
    }
  }

  return [string]::Join(';', $resolved)
}

function Get-PixiNinjaPath([string]$ProjectRoot) {
  # Check global tools in PATH first (from ~/.pixi/bin or WinGet links)
  $globalNinjaPath = Get-GlobalToolPath "ninja"
  if ($globalNinjaPath) {
    return $globalNinjaPath
  }

  # Fall back to per-repo pixi environment
  $pixiEnvRoot = $null
  try {
    $pixiEnvRoot = Get-PixiEnvironmentRoot -ProjectRoot $ProjectRoot
  } catch {
    # No pixi environment found — fall through to error
  }

  if ($pixiEnvRoot) {
    $ninjaPath = Join-Path $pixiEnvRoot "Library\bin\ninja.exe"
    if (Test-Path -LiteralPath $ninjaPath) {
      return (Resolve-Path -LiteralPath $ninjaPath).Path
    }
  }

  if ($pixiEnvRoot) {
    throw "pixi ninja.exe not found at $ninjaPath and not in PATH. Run './kog self install-prereq'."
  } else {
    throw "ninja.exe not found in PATH and no pixi environment found. Run './kog self install-prereq' to install pixi environment."
  }
}

function Invoke-CmdChain([string]$CmdLine) {
  cmd.exe /d /s /c $CmdLine
  if (-not $?) { exit $LASTEXITCODE }
}

function Run-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset) -or [string]::IsNullOrWhiteSpace($BuildPreset)) {
    throw "Root, ConfigurePreset, and BuildPreset are required"
  }
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  # Validate that the selected MSVC toolset has all required headers
  Validate-MsvcToolsetHeaders -VcvarsVersion $VcvarsVersion

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath
  $pixiPathPrefix = Get-PixiBuildToolPrefix -ProjectRoot $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) { $configureCommand += " " + $additionalArgument }

  $vcvarsCommand = ('call "{0}" {1} -vcvars_ver={2}' -f $resolvedVcvars, $Arch, $VcvarsVersion)
  # Run vcvarsall, cmake configure, AND cmake build ALL in one cmd.exe subprocess so
  # that the env vars (INCLUDE, LIB, PATH, etc.) set by vcvarsall persist for both
  # the configure and build steps. Splitting into separate Invoke-CmdChain calls would
  # lose those env vars when each subprocess exits.
  $buildCommand = $vcvarsCommand + ' && set "PATH=' + $pixiPathPrefix + ';%PATH%" && ' + $configureCommand + ' && cmake --build --preset ' + $BuildPreset
  Invoke-CmdChain $buildCommand
}

function Configure-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset)) {
    throw "Root and ConfigurePreset are required"
  }
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  # Validate that the selected MSVC toolset has all required headers
  Validate-MsvcToolsetHeaders -VcvarsVersion $VcvarsVersion

  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath
  $pixiPathPrefix = Get-PixiBuildToolPrefix -ProjectRoot $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) { $configureCommand += " " + $additionalArgument }

  $vcvarsCommand = ('call "{0}" {1} "-vcvars_ver={2}"' -f $resolvedVcvars, $Arch, $VcvarsVersion)
  Invoke-CmdChain ('{0} && set "PATH={1};%PATH%" && {2}' -f $vcvarsCommand, $pixiPathPrefix, $configureCommand)
}

function Build-Presets {
  $allPresets = @(
    @{ Name = "windows-ninja-msvc";         Config = "Debug";   Arch = "x64" },
    @{ Name = "windows-ninja-msvc";         Config = "Release"; Arch = "x64" },
    @{ Name = "windows-ninja-msvc";         Config = "Debug";   Arch = "x86" },
    @{ Name = "windows-ninja-msvc";         Config = "Release"; Arch = "x86" },
    @{ Name = "windows-ninja-msvc-arm64";   Config = "Debug";   Arch = "arm64" },
    @{ Name = "windows-ninja-msvc-arm64";   Config = "Release"; Arch = "arm64" }
  )

  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  # Validate that the selected MSVC toolset has all required headers
  Validate-MsvcToolsetHeaders -VcvarsVersion $VcvarsVersion

  $rootPath = if ([string]::IsNullOrWhiteSpace($Root)) { pwd } else { (Resolve-Path -LiteralPath $Root).Path }
  Set-Location -LiteralPath $rootPath

  $pixiPathPrefix = Get-PixiBuildToolPrefix -ProjectRoot $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  foreach ($preset in $allPresets) {
    $configurePreset = $preset.Name
    $buildPreset = "$($preset.Name)-$($preset.Config.ToLower())"
    $presetArch = $preset.Arch

    $vcvarsCommand = ('call "{0}" {1} -vcvars_ver={2}' -f $resolvedVcvars, $presetArch, $VcvarsVersion)
    $configureCommand = "cmake --preset $configurePreset"
    $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
    foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments)) { $configureCommand += " " + $additionalArgument }

    Write-Host "=== Configuring $configurePreset ($presetArch) ===" -ForegroundColor Cyan
    Invoke-CmdChain ('{0} && set "PATH={1};%PATH%" && {2}' -f $vcvarsCommand, $pixiPathPrefix, $configureCommand)

    Write-Host "=== Building $buildPreset ===" -ForegroundColor Green
    Invoke-CmdChain ('{0} && set "PATH={1};%PATH%" && cmake --build --preset {2}' -f $vcvarsCommand, $pixiPathPrefix, $buildPreset)
  }
}

function Kano-TestPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  return [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)
}

function Validate-MsvcToolsetHeaders {
  param([string]$VcvarsVersion)
  
  # Detect Visual Studio root from vcvarsall location
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { 
    $resolvedVcvars = Detect-Vcvarsall 
  }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { 
    throw "vcvarsall.bat not found; cannot validate toolset headers"
  }
  
  # Extract Visual Studio root from vcvarsall path
  # e.g., C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat
  # Walk up 3 levels: Build → Auxiliary → VC (now at VC)
  # Then walk up 1 more: VC → Community (now at installation root like Community/Professional/Enterprise)
  $vsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedVcvars)))
  
  # Construct toolset include directory path
  # e.g., C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\include
  $toolsetInclude = Join-Path $vsRoot "VC\Tools\MSVC\$VcvarsVersion\include"
  
  # Required header files for a native C++ build
  $requiredHeaders = @("string", "filesystem", "chrono", "vcruntime.h")
  $missingHeaders = @()
  
  foreach ($header in $requiredHeaders) {
    $headerPath = Join-Path $toolsetInclude $header
    if (-not (Test-Path -LiteralPath $headerPath)) {
      $missingHeaders += $header
    }
  }
  
  if ($missingHeaders.Count -gt 0) {
    $missingList = [string]::Join(", ", $missingHeaders)
    throw "Selected MSVC toolset ($VcvarsVersion) is incomplete. Missing core headers: $missingList. " + `
          "Expected location: $toolsetInclude. Please repair or reinstall the matching Visual Studio toolset, " + `
          "or override with -VcvarsVersion or KANO_VCVARS_VERSION to use a different toolset."
  }
}

switch ($Action) {
  "detect-vcvarsall" {
    $found = Detect-Vcvarsall
    if ($found) { Write-Output $found }
  }
  "detect-vsdevcmd" {
    $found = Detect-VsDevCmd
    if ($found) { Write-Output $found }
  }
  "test-path" {
    if ([string]::IsNullOrWhiteSpace($Path)) { exit 1 }
    $exists = Kano-TestPath -LiteralPath $Path
    if ($exists) { exit 0 } else { exit 1 }
  }
  "run-preset" {
    Run-Preset
  }
  "configure-preset" {
    Configure-Preset
  }
  "build-presets" {
    Build-Presets
  }
  default {
    throw "Unknown action: $Action"
  }
}