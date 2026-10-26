<#
.SYNOPSIS
  Invokes a RAD Studio main-menu command through UI Automation (test helper).
  The IDE's main menu is an action menu bar, not a Win32 HMENU, so menu
  commands are reached through UIA ExpandCollapse/Invoke patterns.
.EXAMPLE
  .\UiaMenu.ps1 -ProcessId 1234 -Path 'Tools','Ctrl+Calm','Show/Hide Mixer'
  .\UiaMenu.ps1 -ProcessId 1234 -Path 'Tools','Ctrl+Calm' -List
#>
param(
  [Parameter(Mandatory)] [int] $ProcessId,
  [Parameter(Mandatory)] [string[]] $Path,
  [switch] $List
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$C = [System.Windows.Automation.TreeScope]
$cond = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $ProcessId)

function Find-Item([System.Windows.Automation.AutomationElement] $root, [string] $name, [int] $timeoutMs = 5000) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  do {
    $items = $root.FindAll($C::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)))
    foreach ($i in $items) {
      $n = $i.Current.Name -replace '&', ''
      if ($n -like "$name*") { return $i }
    }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::Now -lt $deadline)
  return $null
}

$main = $A::RootElement.FindFirst($C::Children, $cond)
if (-not $main) { Write-Output 'NOWINDOW'; exit 3 }
$scope = $A::RootElement
for ($k = 0; $k -lt $Path.Count; $k++) {
  $item = Find-Item $scope $Path[$k]
  if (-not $item) { Write-Output "NOTFOUND:$($Path[$k])"; exit 1 }
  $last = $k -eq $Path.Count - 1
  if ($last -and -not $List) {
    $p = $null
    if ($item.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref] $p)) { $p.Invoke() }
    Write-Output "INVOKED:$($item.Current.Name)"
    exit 0
  }
  $p = $null
  if ($item.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref] $p)) { $p.Expand() }
  elseif ($item.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref] $p)) { $p.Invoke() }
  Start-Sleep -Milliseconds 400
}
$items = $A::RootElement.FindAll($C::Descendants, (New-Object System.Windows.Automation.AndCondition($cond, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)))))
foreach ($i in $items) { Write-Output "ITEM:$($i.Current.Name)" }
# close menus
[System.Windows.Forms.SendKeys] | Out-Null
