<#
.SYNOPSIS
  Compiles one Ctrl+Calm project (.dpr or .dpk) with the RAD Studio command-line compiler.

.DESCRIPTION
  Locates the newest installed RAD Studio (or the one given by -BdsVersion), then runs
  dcc32 or dcc64 with the Ctrl+Calm unit search path. All output goes below build\ in
  the repository root, outside the tracked source folders.

.EXAMPLE
  .\scripts\build\Compile.ps1 -Project tests\CtrlCalmTests.dpr -Platform Win64
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Project,
  [ValidateSet('Win32', 'Win64')] [string] $Platform = 'Win32',
  [ValidateSet('Debug', 'Release')] [string] $Config = 'Debug',
  [string] $BdsVersion,
  [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Find-Bds {
  param([string] $Version)
  $base = 'HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS'
  if (-not (Test-Path $base)) { $base = 'HKCU:\Software\Embarcadero\BDS' }
  $keys = Get-ChildItem $base -ErrorAction SilentlyContinue |
    Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RootDir }
  if ($Version) { $keys = $keys | Where-Object PSChildName -eq $Version }
  $key = $keys | Sort-Object { [double]$_.PSChildName } -Descending | Select-Object -First 1
  if (-not $key) { throw "No RAD Studio installation found$(if ($Version) { " for BDS $Version" })." }
  [pscustomobject]@{
    Version = $key.PSChildName
    RootDir = (Get-ItemProperty $key.PSPath).RootDir.TrimEnd('\')
  }
}

$bds = Find-Bds $BdsVersion
$compiler = if ($Platform -eq 'Win32') { 'dcc32.exe' } else { 'dcc64.exe' }
$dcc = Join-Path $bds.RootDir "bin\$compiler"
if (-not (Test-Path $dcc)) { throw "Compiler not found: $dcc" }

$projectPath = (Resolve-Path (Join-Path $Root $Project)).Path
$label = switch ($bds.Version) { '37.0' { 'RAD13' } '23.0' { 'RAD12' } '22.0' { 'RAD11' } default { "BDS$($bds.Version)" } }
$out = Join-Path $Root "build\$label\$Platform\$Config"
$bin = Join-Path $out 'bin'
$dcu = Join-Path $out ('dcu\' + [IO.Path]::GetFileNameWithoutExtension($projectPath))
New-Item -ItemType Directory -Force $bin, $dcu | Out-Null

$srcDirs = 'src\Core', 'src\Audio', 'src\Threading', 'src\Timer', 'src\Persistence', 'src\UI', 'src\IDE', 'tests\Common' |
  ForEach-Object { Join-Path $Root $_ }
$unitPath = ($srcDirs -join ';')
$resPath = (Join-Path $Root 'src\UI') + ';' + (Join-Path $Root 'src\IDE')

$args = @(
  '-Q', '-B',
  '-NSSystem;Winapi;Vcl;System.Win;Vcl.Imaging',
  "-U$unitPath", "-I$unitPath", "-R$resPath",
  "-NU$dcu", "-E$bin",
  "-LE$bin", "-LN$bin", "-NB$bin", "-NH$bin"
)
if ($Config -eq 'Debug') { $args += '-$D+', '-$L+', '-$Y+', '-$C+', '-DDEBUG' }
else { $args += '-$D-', '-$L-', '-$Y-', '-$C-', '-$O+', '-DRELEASE' }
$args += $projectPath

if (-not $Quiet) { Write-Host "BDS $($bds.Version) $compiler $Config -> $bin" }
# "in" clauses in .dpr/.dpk files are relative to the project folder.
Push-Location (Split-Path $projectPath)
try {
  & $dcc @args | Out-Host
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($code -ne 0) { throw "Compilation failed ($compiler exit code $code)." }
$bin
