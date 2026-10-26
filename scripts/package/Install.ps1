<#
.SYNOPSIS
  Installs the Ctrl+Calm design-time package into RAD Studio for the current user.

.DESCRIPTION
  1. Builds the Release package for the requested IDE platforms (unless -SkipBuild).
  2. Copies the packages to <InstallDir>\Win32 and <InstallDir>\Win64 and the sounds
     plus license files to <InstallDir>\sounds (shared by both IDE bitnesses).
  3. Registers each package under HKCU\Software\Embarcadero\<Profile>\<BDS>\
     "Known Packages" (32-bit IDE) or "Known Packages x64" (64-bit IDE).
  Nothing is written to the RAD Studio installation folder and no administrator
  rights are needed. Close RAD Studio before installing.

.PARAMETER RegistryProfile
  Registry profile name. 'BDS' is the normal IDE. Use another name together with
  "bds.exe -r<RegistryProfile>" to try Ctrl+Calm in an isolated IDE profile first.

.EXAMPLE
  .\scripts\package\Install.ps1
  .\scripts\package\Install.ps1 -RegistryProfile CtrlCalmTest   # then run: bds.exe -rCtrlCalmTest
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateSet('Win32', 'Win64', 'Both')] [string] $Platform = 'Both',
  [string] $RegistryProfile = 'BDS',
  [string] $BdsVersion = '37.0',
  [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'CtrlCalm\RAD13'),
  [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$platforms = if ($Platform -eq 'Both') { 'Win32', 'Win64' } else { @($Platform) }
$description = 'Ctrl+Calm - ambient sounds and focus timer'

if (Get-Process bds -ErrorAction SilentlyContinue) {
  Write-Warning 'RAD Studio is running. Close it first; the IDE rewrites the package list on exit.'
}

$soundsSrc = Join-Path $Root 'assets\sounds'
if (-not (Test-Path (Join-Path $soundsSrc 'manifest.json'))) { throw "Sounds not found in $soundsSrc" }

New-Item -ItemType Directory -Force $InstallDir | Out-Null
$soundsDst = Join-Path $InstallDir 'sounds'
New-Item -ItemType Directory -Force $soundsDst | Out-Null
Copy-Item (Join-Path $soundsSrc '*') $soundsDst -Force
Copy-Item (Join-Path $Root 'assets\ATTRIBUTION.md'), (Join-Path $Root 'assets\LICENSES.md'), (Join-Path $Root 'LICENSE') $InstallDir -Force

foreach ($p in $platforms) {
  if ($SkipBuild) {
    $label = switch ($BdsVersion) { '37.0' { 'RAD13' } '23.0' { 'RAD12' } '22.0' { 'RAD11' } default { "BDS$BdsVersion" } }
    $bin = Join-Path $Root "build\$label\$p\Release\bin"
  } else {
    $bin = & (Join-Path $Root 'scripts\build\Compile.ps1') -Project 'packages\RADStudio13\CtrlCalm.dpk' -Platform $p -Config Release -BdsVersion $BdsVersion -Quiet
  }
  $bpl = Get-ChildItem $bin -Filter 'CtrlCalm*.bpl' | Select-Object -First 1
  if (-not $bpl) { throw "Package not found in $bin" }
  $dst = Join-Path $InstallDir $p
  New-Item -ItemType Directory -Force $dst | Out-Null
  Copy-Item $bpl.FullName $dst -Force
  $installed = Join-Path $dst $bpl.Name

  $key = "HKCU:\Software\Embarcadero\$RegistryProfile\$BdsVersion\" + $(if ($p -eq 'Win32') { 'Known Packages' } else { 'Known Packages x64' })
  if ($PSCmdlet.ShouldProcess($key, "Register $installed")) {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $installed -Value $description -PropertyType String -Force | Out-Null
    $disabled = "HKCU:\Software\Embarcadero\$RegistryProfile\$BdsVersion\" + $(if ($p -eq 'Win32') { 'Disabled Packages' } else { 'Disabled Packages x64' })
    if (Test-Path $disabled) { Remove-ItemProperty -Path $disabled -Name $installed -ErrorAction SilentlyContinue }
  }
  Write-Host "Installed $p package: $installed" -ForegroundColor Green
}
Write-Host "Sounds: $soundsDst"
Write-Host 'Start RAD Studio and open Tools > Ctrl+Calm > Show/Hide Mixer.'
