<#
.SYNOPSIS
  Removes Ctrl+Calm from RAD Studio for the current user.

.DESCRIPTION
  Unregisters every CtrlCalm*.bpl from "Known Packages" and "Known Packages x64"
  of the given profile and deletes the install folder. Settings and favorites in
  %APPDATA%\CtrlCalm are kept unless -RemoveSettings is given. Close RAD Studio
  first.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $RegistryProfile = 'BDS',
  [string] $BdsVersion = '37.0',
  [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'CtrlCalm\RAD13'),
  [switch] $RemoveSettings
)

$ErrorActionPreference = 'Stop'
foreach ($list in 'Known Packages', 'Known Packages x64', 'Disabled Packages', 'Disabled Packages x64') {
  $key = "HKCU:\Software\Embarcadero\$RegistryProfile\$BdsVersion\$list"
  if (-not (Test-Path $key)) { continue }
  $item = Get-Item $key
  foreach ($name in $item.GetValueNames()) {
    if ([IO.Path]::GetFileName($name) -like 'CtrlCalm*.bpl') {
      if ($PSCmdlet.ShouldProcess("$key\$name", 'Unregister')) {
        Remove-ItemProperty -Path $key -Name $name
        Write-Host "Unregistered $name ($list)"
      }
    }
  }
}
if ((Test-Path $InstallDir) -and $PSCmdlet.ShouldProcess($InstallDir, 'Delete')) {
  Remove-Item -Recurse -Force $InstallDir
  Write-Host "Deleted $InstallDir"
}
$settings = Join-Path $env:APPDATA 'CtrlCalm'
if ($RemoveSettings -and (Test-Path $settings) -and $PSCmdlet.ShouldProcess($settings, 'Delete')) {
  Remove-Item -Recurse -Force $settings
  Write-Host "Deleted $settings"
} elseif (Test-Path $settings) {
  Write-Host "Kept settings and favorites in $settings (use -RemoveSettings to delete)."
}
