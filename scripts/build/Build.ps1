<#
.SYNOPSIS
  Builds the Ctrl+Calm IDE package, tests and harness, and optionally runs the tests.

.EXAMPLE
  .\scripts\build\Build.ps1                 # Release package for Win32 + Win64
  .\scripts\build\Build.ps1 -Test           # also build and run the test suite
  .\scripts\build\Build.ps1 -Test -NoDevice # tests without opening an audio device
#>
[CmdletBinding()]
param(
  [ValidateSet('Win32', 'Win64', 'Both')] [string] $Platform = 'Both',
  [ValidateSet('Debug', 'Release')] [string] $Config = 'Release',
  [string] $BdsVersion,
  [switch] $Test,
  [switch] $NoDevice,
  [switch] $Harness
)

$ErrorActionPreference = 'Stop'
$compile = Join-Path $PSScriptRoot 'Compile.ps1'
$platforms = if ($Platform -eq 'Both') { 'Win32', 'Win64' } else { @($Platform) }
$failed = 0

foreach ($p in $platforms) {
  $common = @{ Platform = $p; BdsVersion = $BdsVersion }
  $bin = & $compile -Project 'packages\RADStudio13\CtrlCalm.dpk' -Config $Config @common
  Write-Host "Package: $bin" -ForegroundColor Green
  if ($Harness) {
    & $compile -Project 'demos\StandaloneMixerHarness\CtrlCalmHarness.dpr' -Config Debug @common | Out-Null
  }
  if ($Test) {
    $testBin = & $compile -Project 'tests\CtrlCalmTests.dpr' -Config Debug @common
    $exe = Join-Path $testBin 'CtrlCalmTests.exe'
    $testArgs = @()
    if ($NoDevice) { $testArgs += '/nodevice' }
    & $exe @testArgs
    if ($LASTEXITCODE -ne 0) { $failed += $LASTEXITCODE }
  }
}
if ($failed -ne 0) { throw "$failed test(s) failed." }
