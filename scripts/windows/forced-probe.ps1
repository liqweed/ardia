param(
  [Parameter(Mandatory = $true)][string]$Setup,
  [Parameter(Mandatory = $true)][string]$Out,
  [Parameter(Mandatory = $true)][ValidateSet("slow-js", "native-hold")][string]$Mode,
  [double[]]$Offsets = @(0.3, 0.8, 1.5, 2.2, 2.8),
  [int]$Repeats = 3,
  [int]$WatchSeconds = 30
)

$ErrorActionPreference = "Stop"
function Get-BrowserProcesses([object[]]$Running) {
  return @($Running | Where-Object { $_ -and $_.CommandLine -and $_.CommandLine -notmatch '(^|\s)"?--type=' })
}

Add-Type -Namespace ForcedProbe -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr window, System.Text.StringBuilder name, int size);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr window, IntPtr state);
public static System.Collections.Generic.List<string> AppWindows() {
  var found = new System.Collections.Generic.List<string>();
  EnumWindows((window, state) => {
    if (!IsWindowVisible(window)) return true;
    var name = new System.Text.StringBuilder(128); GetClassNameW(window, name, 128);
    if (name.ToString() != "Microsoft.UI.Windowing.Window") return true;
    uint owner; GetWindowThreadProcessId(window, out owner);
    found.Add(window.ToInt64().ToString() + ":" + owner.ToString());
    return true;
  }, IntPtr.Zero);
  return found;
}
'@

$entry = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{47A92F18-32B0-4548-A1EF-72C217FE1836}_is1"
$folder = Join-Path $env:LOCALAPPDATA "Programs\Ardia"
$exe = Join-Path $folder "Ardia.exe"
$marker = Join-Path $folder "Ardia.test-build"
$port = 9462
$quitMarker = if ($Mode -eq "slow-js") { 'test: the answer to willQuit waits' } else { 'test: the quit waits' }
$stretch = if ($Mode -eq "slow-js") { "quitAnswerDelayMs=3000" } else { "quitWaitMs=3000" }
$Out = [IO.Path]::GetFullPath($Out)
$data = Join-Path (Split-Path -Parent $Out) "forced-probe-data-$Mode"
$rows = New-Object System.Collections.Generic.List[object]
$details = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Note([string]$line) {
  Write-Host "forced-probe $Mode`: $line"
  $script:notes.Add($line)
}

function Browsers { return @(Get-BrowserProcesses @(Get-CimInstance Win32_Process -Filter "Name='Ardia.exe'")) }

function Visible-Windows {
  $found = @()
  foreach ($item in [ForcedProbe.Native]::AppWindows()) {
    $parts = $item.Split(":")
    $found += [pscustomobject]@{ Hwnd = [long]$parts[0]; Pid = [int]$parts[1] }
  }
  return $found
}

function Close-All([string]$what) {
  foreach ($round in 1..3) {
    $browsers = @(Browsers)
    if (-not $browsers.Count) { return }
    $ids = @($browsers | ForEach-Object { [int]$_.ProcessId })
    foreach ($window in @(Visible-Windows | Where-Object { $ids -contains $_.Pid })) {
      [ForcedProbe.Native]::PostMessageW([IntPtr]$window.Hwnd, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero) | Out-Null
    }
    $deadline = (Get-Date).AddSeconds(30)
    while (@(Browsers).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  }
  $left = @(Browsers)
  if ($left.Count) {
    Note "$what`: $($left.Count) Ardia still running after closing its windows three times; stopped"
    foreach ($browser in $left) { Stop-Process -Id $browser.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
  }
}

function Log-Lines([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  return @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
}

function Wait-Marker([string]$path, [Diagnostics.Stopwatch]$clock, [int]$seconds) {
  while ($clock.Elapsed.TotalSeconds -lt $seconds) {
    if (@(Log-Lines $path | Where-Object { $_ -match [regex]::Escape($quitMarker) }).Count) { return [int]$clock.ElapsedMilliseconds }
    Start-Sleep -Milliseconds 20
  }
  return $null
}

function Link-Opened([string]$name) {
  try {
    $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 1)
    return [bool](@($targets | Where-Object { $_.url -like "*$name.html" }).Count)
  } catch {
    return $false
  }
}

function Format-Ms($value) { if ($null -eq $value) { return "-" } return "$value" }

function Run-Round([double]$offset, [int]$repeat) {
  $name = "$Mode-o$offset-r$repeat"
  $oldLog = Join-Path $Out "$name-old.log"
  $newLog = Join-Path $Out "$name-new.log"
  $page = Join-Path $data "pages\$name.html"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $page) | Out-Null
  Set-Content -LiteralPath $page -Value "<!doctype html><meta charset=utf-8><title>$name</title><p>$name</p>" -Encoding utf8NoBOM
  $link = ([Uri]$page).AbsoluteUri
  Close-All "before $name"

  $old = Start-Process -FilePath $exe -ArgumentList "--log-file=$oldLog" -PassThru
  $null = $old.Handle
  $deadline = (Get-Date).AddSeconds(120)
  $oldWindow = $null
  while (-not $oldWindow -and (Get-Date) -lt $deadline) {
    $oldWindow = @(Visible-Windows | Where-Object { $_.Pid -eq $old.Id }) | Select-Object -First 1
    if (-not $oldWindow) { Start-Sleep -Milliseconds 200 }
  }
  if (-not $oldWindow) { throw "$name`: the first Ardia ($($old.Id)) showed no window within 120 s" }
  Start-Sleep -Seconds 2

  $clock = [Diagnostics.Stopwatch]::StartNew()
  [ForcedProbe.Native]::PostMessageW([IntPtr]$oldWindow.Hwnd, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero) | Out-Null
  $quitMs = Wait-Marker $oldLog $clock 10
  $quitSeen = $null -ne $quitMs
  if (-not $quitSeen) { $quitMs = 0 }
  $launchAt = $quitMs + [int]($offset * 1000)
  while ($clock.ElapsedMilliseconds -lt $launchAt) { Start-Sleep -Milliseconds 5 }
  $new = Start-Process -FilePath $exe -ArgumentList @("--log-file=$newLog", $link) -PassThru
  $null = $new.Handle
  $launchMs = [int]$clock.ElapsedMilliseconds

  $appearances = New-Object System.Collections.Generic.List[object]
  $open = @{}
  $tracked = @{ ([int]$old.Id) = "old"; ([int]$new.Id) = "new" }
  $oldExitMs = $null
  $newExitMs = $null
  $linkMs = $null
  $nextScan = 0
  $nextLink = 0
  $endMs = $launchMs + $WatchSeconds * 1000
  while ($clock.ElapsedMilliseconds -lt $endMs) {
    $now = [int]$clock.ElapsedMilliseconds
    if ($now -ge $nextScan) {
      foreach ($browser in @(Browsers)) { if (-not $tracked.ContainsKey([int]$browser.ProcessId)) { $tracked[[int]$browser.ProcessId] = "other" } }
      $nextScan = $now + 500
    }
    $seen = @{}
    foreach ($window in @(Visible-Windows)) {
      if (-not $tracked.ContainsKey($window.Pid)) { continue }
      $seen[$window.Hwnd] = $true
      if (-not $open.ContainsKey($window.Hwnd)) {
        $appearance = [pscustomobject]@{ Hwnd = $window.Hwnd; Pid = $window.Pid; Role = $tracked[$window.Pid]; FromMs = $now; ToMs = $null }
        $open[$window.Hwnd] = $appearance
        $appearances.Add($appearance)
      }
    }
    foreach ($hwnd in @($open.Keys)) {
      if (-not $seen.ContainsKey($hwnd)) { $open[$hwnd].ToMs = $now; $open.Remove($hwnd) }
    }
    if ($null -eq $oldExitMs -and $old.HasExited) { $oldExitMs = $now }
    if ($null -eq $newExitMs -and $new.HasExited) { $newExitMs = $now }
    if ($null -eq $linkMs -and $now -ge $nextLink) {
      if (Link-Opened $name) { $linkMs = $now }
      $nextLink = $now + 500
    }
    Start-Sleep -Milliseconds 50
  }

  $endBrowsers = @(Browsers)
  $endIds = @($endBrowsers | ForEach-Object { [int]$_.ProcessId })
  $endWindowed = @(Visible-Windows | Where-Object { $endIds -contains $_.Pid } | ForEach-Object Pid | Select-Object -Unique)
  $oldCode = if ($old.HasExited) { $old.ExitCode } else { $null }
  $newCode = if ($new.HasExited) { $new.ExitCode } else { $null }
  $afterLaunch = @($appearances | Where-Object { $_.FromMs -ge $launchMs })
  $vanished = @($afterLaunch | Where-Object { $null -ne $_.ToMs })
  $windowText = if ($afterLaunch.Count) {
    ($afterLaunch | ForEach-Object {
        $life = if ($null -eq $_.ToMs) { "survived" } else { "gone after $($_.ToMs - $_.FromMs) ms" }
        "$($_.Role) $($_.Pid) at +$($_.FromMs - $launchMs) ms, $life"
      }) -join "; "
  } else { "none" }
  $oldText = if ($null -ne $oldExitMs) { "+$($oldExitMs - $launchMs) ms, code $oldCode" } else { "running" }
  $newText = if ($null -ne $newExitMs) { "+$($newExitMs - $launchMs) ms, code $newCode" } else { "running" }
  $linkText = if ($null -ne $linkMs) { "+$($linkMs - $launchMs) ms" } else { "no" }
  $endText = if ($endWindowed.Count -eq 1 -and $endBrowsers.Count -eq 1) { "yes" } elseif ($endBrowsers.Count -eq 0) { "NO: nothing running" } else { "NO: $($endBrowsers.Count) running, $($endWindowed.Count) with a window" }
  $pattern = '(?i)quitting|relaunch|reopen|process ending|start failed|error|fatal|opened|closed|willQuit|test:|launch links|asking the engine|test gate|telemetry and documents'
  $oldLines = @(Log-Lines $oldLog | Where-Object { $_ -match $pattern })
  $newLines = @(Log-Lines $newLog | Where-Object { $_ -match $pattern })
  $row = [pscustomobject]@{
    Offset = $offset; Repeat = $repeat; QuitMs = if ($quitSeen) { $quitMs } else { "not logged" }; LaunchAfterQuitMs = $launchMs - $quitMs
    Windows = $windowText; Vanished = $vanished.Count; Old = $oldText; New = $newText; Link = $linkText; End = $endText
    NewLogged = (Log-Lines $newLog).Count
  }
  $script:rows.Add($row)
  $script:details.Add("### $name")
  $script:details.Add("")
  $script:details.Add("- close posted at 0 ms; quit marker at $(Format-Ms $quitMs) ms$(if (-not $quitSeen) { ' (not logged; the close is the reference)' }); the new launch at $launchMs ms (old pid $($old.Id), new pid $($new.Id))")
  foreach ($appearance in $appearances) { $script:details.Add("- window $($appearance.Hwnd) of $($appearance.Role) $($appearance.Pid): shown $($appearance.FromMs) ms, hidden $(Format-Ms $appearance.ToMs) ms") }
  $script:details.Add("- old exit $oldText; new exit $newText; link $linkText; end: $endText")
  $script:details.Add("")
  $script:details.Add("old log:")
  $script:details.Add('```')
  foreach ($line in $oldLines) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("new log ($((Log-Lines $newLog).Count) lines):")
  $script:details.Add('```')
  foreach ($line in $newLines) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("")
  Write-Host "forced-probe $name`: windows=$windowText old=$oldText new=$newText link=$linkText end=$endText"
  Close-All "after $name"
}

if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) { throw "'$Setup' does not exist" }
if ((Test-Path -LiteralPath $entry) -or (Test-Path -LiteralPath $folder)) { throw "Ardia is already installed for this user" }
$install = Start-Process -FilePath (Resolve-Path -LiteralPath $Setup).Path -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "the installer exited with $($install.ExitCode)" }
Note "installed $Setup ($((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)); mode $Mode with ARDIA_TEST=$stretch"

Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $data | Out-Null
Set-Content -LiteralPath (Join-Path $data "onboarding.json") -Value '{"completedAt":1700000000000,"version":1}' -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $data "config.json") -Value '{"settings":{"openLinksInLittleArdia":false}}' -Encoding utf8NoBOM
Set-Content -LiteralPath $marker -Value "forced-probe" -Encoding ascii
$env:ARDIA_BACKGROUND = "1"
$env:ARDIA_DATA_DIR = $data
$env:ARDIA_TEST = $stretch
$env:ARDIA_REMOTE_DEBUGGING_PORT = "$port"

try {
  foreach ($offset in $Offsets) {
    foreach ($repeat in 1..$Repeats) {
      try { Run-Round $offset $repeat }
      catch {
        Note "offset $offset round $repeat failed in the probe: $($_.Exception.Message)"
        Close-All "after a probe error"
      }
    }
  }
  $first = Join-Path $Out "$Mode-o$($Offsets[0])-r1-old.log"
  $gate = @(Log-Lines $first | Where-Object { $_ -match 'test gate:' } | Select-Object -First 1)
  Note "test gate in the first round: $(if ($gate.Count) { $gate[0] } else { 'no line' })"
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -in @("Application Error", "Windows Error Reporting") -and $_.Message -match "Ardia\.exe" })
  Note "Application log Ardia crash events: $($events.Count)"
  $dumps = @(Get-ChildItem -LiteralPath $data -Recurse -File -Filter *.dmp -ErrorAction SilentlyContinue)
  Note "crash dumps under the profile: $($dumps.Count)"
} finally {
  Close-All "at the end"
  Get-Process -Name Ardia -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
  $report = New-Object System.Collections.Generic.List[string]
  $report.Add("## Forced relaunch probe on nightly.3: $Mode")
  $report.Add("")
  foreach ($line in $notes) { $report.Add("- $line") }
  $report.Add("")
  $report.Add("| offset s | round | quit marker ms after close | launch ms after quit | windows after the launch | vanished | old exit (after launch) | new exit (after launch) | link opened | one Ardia with a window at end | new log lines |")
  $report.Add("|---|---|---|---|---|---|---|---|---|---|---|")
  foreach ($row in $rows) {
    $report.Add("| $($row.Offset) | $($row.Repeat) | $($row.QuitMs) | $($row.LaunchAfterQuitMs) | $($row.Windows -replace '\|', '/') | $($row.Vanished) | $($row.Old) | $($row.New) | $($row.Link) | $($row.End) | $($row.NewLogged) |")
  }
  $report.Add("")
  foreach ($line in $details) { $report.Add($line) }
  $report | Set-Content -LiteralPath (Join-Path $Out "forced-probe.md")
  if ($env:GITHUB_STEP_SUMMARY) { $report | Select-Object -First ($rows.Count + 20) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
}
