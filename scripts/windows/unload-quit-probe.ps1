param(
  [Parameter(Mandatory = $true)][string]$Setup,
  [Parameter(Mandatory = $true)][string]$Out,
  [Parameter(Mandatory = $true)][string]$Label,
  [string[]]$Cases = @("control", "unload", "download", "control", "unload", "download", "unload-answered", "download-answered"),
  [int]$CloseWatchSeconds = 30,
  [int]$RelaunchWatchSeconds = 60,
  [int]$Port = 9461
)

$ErrorActionPreference = "Stop"

Add-Type -Namespace UnloadProbe -Name Native -UsingNamespace System.Text, System.Collections.Generic -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr window, IntPtr state);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr window, StringBuilder name, int size);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr window, StringBuilder text, int size);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
[DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
public class WindowFact { public long Handle; public uint ProcessId; public string ClassName; public string Title; public long Owner; public int Left; public int Top; public int Right; public int Bottom; }
public static string ClassOf(IntPtr window) { var name = new StringBuilder(256); GetClassNameW(window, name, 256); return name.ToString(); }
public static List<WindowFact> VisibleWindowsOf(HashSet<uint> processes) {
  var found = new List<WindowFact>();
  EnumWindows((window, state) => {
    if (!IsWindowVisible(window)) return true;
    uint owner; GetWindowThreadProcessId(window, out owner);
    if (!processes.Contains(owner)) return true;
    Rect rect; GetWindowRect(window, out rect);
    if (rect.Right - rect.Left <= 1 || rect.Bottom - rect.Top <= 1) return true;
    var text = new StringBuilder(512); GetWindowTextW(window, text, 512);
    found.Add(new WindowFact { Handle = window.ToInt64(), ProcessId = owner, ClassName = ClassOf(window), Title = text.ToString(), Owner = GetWindow(window, 4).ToInt64(), Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom });
    return true;
  }, IntPtr.Zero);
  return found;
}
'@
[UnloadProbe.Native]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$appWindowClass = "Microsoft.UI.Windowing.Window"
$entry = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{47A92F18-32B0-4548-A1EF-72C217FE1836}_is1"
$folder = Join-Path $env:LOCALAPPDATA "Programs\Ardia"
$exe = Join-Path $folder "Ardia.exe"
$data = Join-Path $env:LOCALAPPDATA "Ardia"
$seed = Join-Path ([System.IO.Path]::GetTempPath()) "ardia-unload-probe-seed"
$downloads = Join-Path $env:USERPROFILE "Downloads"
$keyLinePattern = 'quitting|asking the engine to quit|process ending|quitCancelled|telemetry and documents written'
$widerLinePattern = '(?i)quit|process ending|telemetry and documents|unload|download|dialog|cancel|launch guard|handed|took over|start failed|fatal|^error|js-error|first window|window \S+ closed|instance'
$started = Get-Date
$notes = New-Object System.Collections.Generic.List[string]
$rows = New-Object System.Collections.Generic.List[object]
$details = New-Object System.Collections.Generic.List[string]
$browserKinds = @{}
$heldProcesses = @{}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$serverLog = Join-Path $Out "server.log"
$serverScript = Join-Path $Out "server.ps1"

function Note([string]$line) {
  Write-Host "unload-probe $Label`: $line"
  $script:notes.Add($line)
}

function Save-Shot([string]$path) {
  try {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
  } catch { Write-Host "screenshot $path failed: $($_.Exception.Message)" }
}

function Ardia-Processes { return @(Get-Process -Name Ardia -ErrorAction SilentlyContinue) }

function Is-Browser($process) {
  $key = "$($process.Id)"
  try { $key = "$($process.Id)@$($process.StartTime.Ticks)" } catch { }
  if (-not $script:browserKinds.ContainsKey($key)) {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue
    if (-not $cim) { return $false }
    $script:browserKinds[$key] = -not ($cim.CommandLine -match '(^|\s)"?--type=')
  }
  return $script:browserKinds[$key]
}

function Browser-Ids {
  $ids = @()
  foreach ($process in Ardia-Processes) { if (Is-Browser $process) { $ids += [int]$process.Id } }
  return $ids
}

function Hold-Process([int]$processId) {
  if ($script:heldProcesses.ContainsKey($processId)) { return }
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($process) {
    try { $process.Handle | Out-Null } catch { }
    $script:heldProcesses[$processId] = $process
  }
}

function Exit-Text([int]$processId, [datetime]$since) {
  $process = $script:heldProcesses[$processId]
  if (-not $process) { return "?" }
  try { $process.Refresh() } catch { }
  if (-not $process.HasExited) { return "running" }
  $code = "?"; $at = "?"
  try { $code = $process.ExitCode } catch { }
  try { $at = [int]($process.ExitTime - $since).TotalMilliseconds } catch { }
  return "code $code at $at ms"
}

function Visible-Windows([int[]]$ids) {
  $set = New-Object 'System.Collections.Generic.HashSet[uint32]'
  foreach ($id in $ids) { [void]$set.Add([uint32]$id) }
  if ($set.Count -eq 0) { return @() }
  return @([UnloadProbe.Native]::VisibleWindowsOf($set))
}

function App-Windows {
  $ids = @(Browser-Ids)
  return @(Visible-Windows $ids | Where-Object { $_.ClassName -eq $appWindowClass })
}

function Wait-AppWindow([int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $shown = @(App-Windows)
    if ($shown.Count) { return $shown[0] }
    Start-Sleep -Milliseconds 250
  }
  return $null
}

function Read-Lines([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  try {
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
      $reader = New-Object System.IO.StreamReader $stream
      return @($reader.ReadToEnd() -split "`r?`n" | Where-Object { $_ -ne "" })
    } finally { $stream.Dispose() }
  } catch { return @() }
}

function Server-Lines { return @(Read-Lines $serverLog) }

function Server-Since([int]$mark) { return @(Server-Lines | Select-Object -Skip $mark) }

function Wait-ServerLine([int]$mark, [string]$pattern, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    $hit = @(Server-Since $mark | Where-Object { $_ -match $pattern } | Select-Object -First 1)
    if ($hit.Count) { return $hit[0] }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $null
}

function Bring-Forward([IntPtr]$window, [int]$owner) {
  foreach ($attempt in 1..6) {
    [UnloadProbe.Native]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 200
    [uint32]$foregroundOwner = 0
    [UnloadProbe.Native]::GetWindowThreadProcessId([UnloadProbe.Native]::GetForegroundWindow(), [ref]$foregroundOwner) | Out-Null
    if ($foregroundOwner -eq $owner) { return $true }
    [UnloadProbe.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [UnloadProbe.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  }
  return $false
}

function Send-Click([int]$x, [int]$y) {
  [UnloadProbe.Native]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  [UnloadProbe.Native]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [UnloadProbe.Native]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}

function Send-Key([byte]$key) {
  [UnloadProbe.Native]::keybd_event($key, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [UnloadProbe.Native]::keybd_event($key, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 200
}

function Root-ClassAt([int]$x, [int]$y) {
  $point = New-Object UnloadProbe.Native+Point
  $point.X = $x
  $point.Y = $y
  $hit = [UnloadProbe.Native]::GetAncestor([UnloadProbe.Native]::WindowFromPoint($point), 2)
  [uint32]$hitOwner = 0
  [UnloadProbe.Native]::GetWindowThreadProcessId($hit, [ref]$hitOwner) | Out-Null
  return "$([UnloadProbe.Native]::ClassOf($hit)) in process $hitOwner"
}

function Describe-Window($fact) { return "$($fact.ProcessId) $($fact.ClassName) '$($fact.Title)' $($fact.Right - $fact.Left)x$($fact.Bottom - $fact.Top)" }

function Partial-Downloads {
  $places = @($downloads, $data) | Where-Object { Test-Path -LiteralPath $_ }
  $found = @()
  foreach ($place in $places) {
    $found += @(Get-ChildItem -LiteralPath $place -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ardia-slow|\.crdownload$' } | ForEach-Object { "$($_.FullName) $($_.Length) bytes" })
  }
  return $found
}

function Stop-Ardia([string]$why) {
  $left = @(Ardia-Processes)
  if ($left.Count) {
    $browsers = @($left | Where-Object { Is-Browser $_ } | ForEach-Object { $_.Id })
    Note "$why`: stopping $($left.Count) Ardia process(es), browsers $($browsers -join ',')"
    $left | Stop-Process -Force -ErrorAction SilentlyContinue
  }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and @(Ardia-Processes).Count) { Start-Sleep -Milliseconds 250 }
}

function Reset-Profile {
  Stop-Ardia "profile reset"
  foreach ($attempt in 1..10) {
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $data)) { break }
    Start-Sleep -Milliseconds 500
  }
  if (Test-Path -LiteralPath $data) { Note "profile reset: $data could not be removed" }
  Copy-Item -LiteralPath $seed -Destination $data -Recurse -Force
  Get-ChildItem -LiteralPath $downloads -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ardia-slow|\.crdownload$' } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Watch-Phase([string]$phase, [int]$seconds, [string]$dir, [string[]]$logs, [hashtable]$known, [bool]$answer, [int[]]$shotsAt) {
  $result = [pscustomobject]@{ Timeline = New-Object System.Collections.Generic.List[string]; Browsers = @{}; Windows = @{}; LogLines = New-Object System.Collections.Generic.List[string]; Answered = New-Object System.Collections.Generic.List[string]; EndBrowsers = @(); EndWindows = @() }
  $lineCounts = @{}
  foreach ($path in $logs) { $lineCounts[$path] = @(Read-Lines $path).Count }
  $answeredHandles = @{}
  $shotsTaken = @{}
  $last = ""
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt ($seconds * 1000)) {
    $tick = [int]$watch.ElapsedMilliseconds
    $browsers = @(Browser-Ids)
    $allIds = @(Ardia-Processes | ForEach-Object { [int]$_.Id })
    $windows = @(Visible-Windows $allIds)
    foreach ($id in $browsers) {
      Hold-Process $id
      if (-not $result.Browsers.ContainsKey($id)) { $result.Browsers[$id] = [pscustomobject]@{ First = $tick; Last = $tick } }
      $result.Browsers[$id].Last = $tick
    }
    foreach ($fact in $windows) {
      $handle = [long]$fact.Handle
      if (-not $result.Windows.ContainsKey($handle)) { $result.Windows[$handle] = [pscustomobject]@{ Fact = $fact; First = $tick; Last = $tick; New = -not $known.ContainsKey($handle) } }
      $result.Windows[$handle].Last = $tick
      $result.Windows[$handle].Fact = $fact
    }
    $state = "browsers [" + ($browsers -join ",") + "] windows [" + (($windows | Sort-Object ProcessId, ClassName | ForEach-Object { Describe-Window $_ }) -join "; ") + "]"
    if ($state -ne $last) { $result.Timeline.Add("$tick ms: $state"); $last = $state }
    foreach ($path in $logs) {
      $lines = @(Read-Lines $path)
      if ($lines.Count -gt $lineCounts[$path]) {
        foreach ($line in @($lines | Select-Object -Skip $lineCounts[$path])) {
          if ($line -match $widerLinePattern) { $result.LogLines.Add("$tick ms [$(Split-Path -Leaf $path)] $($line.Substring(0, [Math]::Min(300, $line.Length)))") }
        }
        $lineCounts[$path] = $lines.Count
      }
    }
    if ($answer) {
      foreach ($fact in $windows) {
        $handle = [long]$fact.Handle
        $record = $result.Windows[$handle]
        if ($record.New -and $fact.ClassName -ne $appWindowClass -and -not $answeredHandles.ContainsKey($handle) -and ($tick - $record.First) -ge 1500) {
          $answeredHandles[$handle] = $true
          $forward = Bring-Forward ([IntPtr]$handle) ([int]$fact.ProcessId)
          Send-Key 0x1B
          $result.Answered.Add("$tick ms: Escape sent to $(Describe-Window $fact) (foreground $forward)")
        }
      }
    }
    foreach ($at in $shotsAt) {
      if (-not $shotsTaken.ContainsKey($at) -and $tick -ge ($at * 1000)) {
        $shotsTaken[$at] = $true
        Save-Shot (Join-Path $dir "$phase-$($at)s.png")
      }
    }
    $wait = 250 - ([int]$watch.ElapsedMilliseconds - $tick)
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
  }
  $result.EndBrowsers = @(Browser-Ids)
  $result.EndWindows = @(Visible-Windows @(Ardia-Processes | ForEach-Object { [int]$_.Id }))
  foreach ($path in $logs) {
    foreach ($line in @(Read-Lines $path | Select-Object -Skip $lineCounts[$path])) {
      if ($line -match $widerLinePattern) { $result.LogLines.Add("end [$(Split-Path -Leaf $path)] $($line.Substring(0, [Math]::Min(300, $line.Length)))") }
    }
  }
  return $result
}

function Key-Lines($phaseResult) {
  $picked = @($phaseResult.LogLines | Where-Object { $_ -match $keyLinePattern } | ForEach-Object {
      if ($_ -match '^(\d+ ms|end) \[[^\]]+\] (.*)$') {
        $when = $Matches[1]
        $text = $Matches[2]
        $short = if ($text -match 'telemetry and documents written in \d+ ms[^,]*') { $Matches[0] } elseif ($text -match '(quitting|asking the engine to quit|process ending|quitCancelled)') { $Matches[1] } else { $text }
        "$short @ $when"
      }
    })
  if (-not $picked.Count) { return "none" }
  return ($picked -join ", ")
}

function Escape-Cell([string]$text) { return ($text -replace '\|', '/' -replace "`r|`n", ' ') }

function Run-Case([int]$index, [string]$case) {
  $name = "{0:D2}-{1}" -f $index, $case
  $dir = Join-Path $Out $name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Reset-Profile
  $route = if ($case -like "control*") { "/plain" } elseif ($case -like "unload*") { "/unload" } else { "/download" }
  $answer = $case -like "*-answered"
  $mark = @(Server-Lines).Count
  $launchLog = Join-Path $dir "launch.log"
  $relaunchLog = Join-Path $dir "relaunch.log"
  $launch = Start-Process -FilePath $exe -ArgumentList "--log-file=`"$launchLog`"", "http://127.0.0.1:$Port$($route)?case=$name" -PassThru
  $app = Wait-AppWindow 180
  if (-not $app) { throw "$name`: no app window within 180 s" }
  $appHandle = [IntPtr]([long]$app.Handle)
  $oldBrowser = [int]$app.ProcessId
  Hold-Process $oldBrowser
  $loaded = Wait-ServerLine $mark "request /event/loaded" 45
  Start-Sleep -Seconds 3
  $windowsBefore = @(Visible-Windows @(Ardia-Processes | ForEach-Object { [int]$_.Id }))
  $pages = @($windowsBefore | Where-Object { $_.ProcessId -eq $oldBrowser -and $_.ClassName -like "Chrome_WidgetWin*" -and $_.Owner -eq [long]$app.Handle } | Sort-Object { ($_.Right - $_.Left) * ($_.Bottom - $_.Top) } -Descending)
  if ($pages.Count) {
    $target = $pages[0]
    $x = [int](($target.Left + $target.Right) / 2); $y = [int](($target.Top + $target.Bottom) / 2)
    $aim = "page window $(Describe-Window $target) centre ($x, $y)"
  } else {
    $x = [int]($app.Left + 0.65 * ($app.Right - $app.Left)); $y = [int](($app.Top + $app.Bottom) / 2)
    $aim = "no owned page window found; app window at ($x, $y)"
  }
  $forward = Bring-Forward $appHandle $oldBrowser
  $hitBefore = Root-ClassAt $x $y
  Send-Click $x $y
  if ($route -ne "/download") { Send-Key 0x41 }
  $activation = Wait-ServerLine $mark "request /event/(pointerdown|keydown)-true\?active=true" 6
  $downloadOpened = $null
  $partialBefore = @()
  if ($route -eq "/download") {
    $downloadOpened = Wait-ServerLine $mark "slow opened" 20
    Start-Sleep -Seconds 3
    $partialBefore = @(Partial-Downloads)
  }
  Save-Shot (Join-Path $dir "before-close.png")
  $known = @{}
  foreach ($fact in @(Visible-Windows @(Ardia-Processes | ForEach-Object { [int]$_.Id }))) { $known[[long]$fact.Handle] = $true }
  $closeMark = @(Server-Lines).Count
  $closedAt = Get-Date
  [UnloadProbe.Native]::PostMessageW($appHandle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero) | Out-Null
  $close = Watch-Phase "close" $CloseWatchSeconds $dir @($launchLog) $known $answer @(2, 10, ($CloseWatchSeconds - 1))
  $afterClose = @(Server-Since $closeMark)
  $partialAfterClose = @(Partial-Downloads)
  $relaunchMark = @(Server-Lines).Count
  $relaunchedAt = Get-Date
  $relaunch = Start-Process -FilePath $exe -ArgumentList "--log-file=`"$relaunchLog`"" -PassThru
  try { $relaunch.Handle | Out-Null } catch { }
  $script:heldProcesses[[int]$relaunch.Id] = $relaunch
  $knownNow = @{}
  foreach ($fact in $close.EndWindows) { $knownNow[[long]$fact.Handle] = $true }
  $again = Watch-Phase "relaunch" $RelaunchWatchSeconds $dir @($launchLog, $relaunchLog) $knownNow $false @(10, ($RelaunchWatchSeconds - 1))
  $afterRelaunch = @(Server-Since $relaunchMark)
  $oldGone = $close.Browsers.ContainsKey($oldBrowser) -and -not ($close.EndBrowsers -contains $oldBrowser)
  $oldText = if (-not $close.Browsers.ContainsKey($oldBrowser)) { "gone before the first sample" } elseif ($oldGone) { "gone by $($close.Browsers[$oldBrowser].Last + 250) ms ($(Exit-Text $oldBrowser $closedAt))" } else { "ALIVE at $CloseWatchSeconds s" }
  $appWindowsAfter = @($close.Windows.Values | Where-Object { $_.Fact.ClassName -eq $appWindowClass })
  $appWindowText = if ($appWindowsAfter.Count) { ($appWindowsAfter | ForEach-Object { "pid $($_.Fact.ProcessId) until $($_.Last) ms" }) -join ", " } else { "none sampled" }
  $newWindows = @($close.Windows.Values | Where-Object { $_.New } | Sort-Object First)
  $newText = if ($newWindows.Count) { ($newWindows | ForEach-Object { "$(Describe-Window $_.Fact) $($_.First)..$($_.Last) ms" }) -join "; " } else { "none" }
  $endBrowsers = @($close.EndBrowsers)
  $endApp = @($close.EndWindows | Where-Object { $_.ClassName -eq $appWindowClass })
  $endState = if (-not $endBrowsers.Count) { "no Ardia" } elseif ($endApp.Count) { "browser $($endBrowsers -join ',') with an app window" } elseif ($close.EndWindows.Count) { "browser $($endBrowsers -join ',') ALIVE, no app window, other windows: " + (($close.EndWindows | ForEach-Object { Describe-Window $_ }) -join "; ") } else { "browser $($endBrowsers -join ',') ALIVE WITH NO WINDOW" }
  $beforeunload = @($afterClose | Where-Object { $_ -match "request /event/beforeunload" })
  $pagehide = @($afterClose | Where-Object { $_ -match "request /event/pagehide" })
  $slowClosed = @($afterClose + $afterRelaunch | Where-Object { $_ -match "slow closed" })
  $relaunchWindows = @($again.Windows.Values | Where-Object { $_.Fact.ClassName -eq $appWindowClass } | Sort-Object First)
  $relaunchWindowText = if ($relaunchWindows.Count) { ($relaunchWindows | ForEach-Object { $role = if ([int]$_.Fact.ProcessId -eq $oldBrowser) { "old browser" } elseif ([int]$_.Fact.ProcessId -eq [int]$relaunch.Id) { "launched process" } else { "other browser" }; "pid $($_.Fact.ProcessId) ($role) from $($_.First) ms" + $(if ($_.Last -lt ($RelaunchWatchSeconds * 1000 - 500)) { " to $($_.Last) ms" } else { " to the end" }) }) -join "; " } else { "NO WINDOW in $RelaunchWatchSeconds s" }
  $relaunchExit = Exit-Text ([int]$relaunch.Id) $relaunchedAt
  $relaunchEndApp = @($again.EndWindows | Where-Object { $_.ClassName -eq $appWindowClass })
  $relaunchEnd = if (-not @($again.EndBrowsers).Count) { "no Ardia" } elseif ($relaunchEndApp.Count) { "window in pid $(($relaunchEndApp | ForEach-Object { $_.ProcessId } | Select-Object -Unique) -join ',')" } else { "browser $(@($again.EndBrowsers) -join ',') with no app window" }
  $row = [pscustomobject]@{
    Case = $name; OldBrowser = $oldBrowser; Activation = $(if ($activation) { "yes" } else { "NO" }); Download = $(if ($route -eq "/download") { if ($downloadOpened) { "streaming; files: $($partialBefore -join ', ')" } else { "NOT STARTED" } } else { "-" })
    Old = $oldText; AppWindow = $appWindowText; NewWindows = $newText; Answered = ($close.Answered -join "; "); KeyLines = (Key-Lines $close); BeforeUnload = $(if ($beforeunload.Count) { $beforeunload[0] -replace '^\S+ request ', '' } else { "-" }); EndState = $endState
    RelaunchPid = [int]$relaunch.Id; RelaunchExit = $relaunchExit; RelaunchWindow = $relaunchWindowText; RelaunchEnd = $relaunchEnd; RelaunchKeyLines = (Key-Lines $again)
  }
  $script:rows.Add($row)
  $script:details.Add("### $Label $name")
  $script:details.Add("")
  $script:details.Add("- launched pid $($launch.Id), app window in browser $oldBrowser; page load beacon: $(if ($loaded) { 'yes' } else { 'no' })")
  $script:details.Add("- click aim: $aim; foreground $forward; under the point: $hitBefore")
  $script:details.Add("- activation beacon: $(if ($activation) { $activation } else { 'none' })")
  if ($route -eq "/download") { $script:details.Add("- download: $(if ($downloadOpened) { $downloadOpened } else { 'no request' }); files before close: $($partialBefore -join ', '); after the close watch: $($partialAfterClose -join ', '); server: $($slowClosed -join ' / ')") }
  $script:details.Add("- page beacons after close: beforeunload $($beforeunload.Count), pagehide $($pagehide.Count)")
  $script:details.Add("- close watch end: $endState")
  if ($close.Answered.Count) { $script:details.Add("- answered: $($close.Answered -join '; ')") }
  $script:details.Add("- relaunch pid $($relaunch.Id): $relaunchExit; windows: $relaunchWindowText; end: $relaunchEnd")
  $script:details.Add("")
  $script:details.Add("Close timeline:")
  $script:details.Add('```')
  foreach ($line in $close.Timeline) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("Close log lines:")
  $script:details.Add('```')
  foreach ($line in $close.LogLines) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("Relaunch timeline:")
  $script:details.Add('```')
  foreach ($line in $again.Timeline) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("Relaunch log lines:")
  $script:details.Add('```')
  foreach ($line in $again.LogLines) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("Server lines from launch on:")
  $script:details.Add('```')
  foreach ($line in @(Server-Since $mark)) { $script:details.Add($line) }
  $script:details.Add('```')
  $script:details.Add("")
  Write-Host "unload-probe $Label $name`: activation=$($row.Activation) download=$($row.Download) old=$oldText new-windows=$newText key=$($row.KeyLines) end=$endState relaunch=$relaunchExit window=$relaunchWindowText relaunch-end=$relaunchEnd"
  Stop-Ardia "after $name"
  $defaultLogs = Join-Path $data "Logs"
  if (Test-Path -LiteralPath $defaultLogs) { Copy-Item -LiteralPath $defaultLogs -Destination (Join-Path $dir "default-logs") -Recurse -Force -ErrorAction SilentlyContinue }
}

Set-Content -LiteralPath $serverScript -Encoding utf8NoBOM -Value @'
param([int]$Port, [string]$Log)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$clock = [Diagnostics.Stopwatch]::StartNew()
$slow = [System.Collections.Generic.List[object]]::new()
$nextDrip = 0
function Write-Log([string]$line) { Add-Content -LiteralPath $Log -Value "$([DateTime]::UtcNow.ToString('HH:mm:ss.fff')) $line" }
function Send-Text($stream, [string]$status, [string]$type, [string]$text) {
  $body = [System.Text.Encoding]::UTF8.GetBytes($text)
  $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: $type`r`nCache-Control: no-store`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
  $stream.Write($head, 0, $head.Length)
  $stream.Write($body, 0, $body.Length)
  $stream.Flush()
}
$events = "<script>const report = (name) => fetch('/event/' + name + '?active=' + navigator.userActivation.hasBeenActive + '&at=' + Date.now(), { keepalive: true }).catch(() => {}); addEventListener('load', () => report('loaded')); addEventListener('pointerdown', (event) => setTimeout(() => report('pointerdown-' + event.isTrusted), 50), true); addEventListener('keydown', (event) => setTimeout(() => report('keydown-' + event.isTrusted), 50), true); addEventListener('pagehide', () => navigator.sendBeacon('/event/pagehide')); addEventListener('visibilitychange', () => report('visibility-' + document.visibilityState));</script>"
$pages = @{
  "/plain" = "<!doctype html><meta charset=utf-8><title>plain page</title><body style='margin:0;height:100vh;background:#e8f4e8;font:28px sans-serif'><p>plain page</p>$events"
  "/unload" = "<!doctype html><meta charset=utf-8><title>unload page</title><body style='margin:0;height:100vh;background:#f8e0e8;font:28px sans-serif'><p>unload page</p><script>onbeforeunload = (e) => { navigator.sendBeacon('/event/beforeunload?active=' + navigator.userActivation.hasBeenActive); e.preventDefault(); e.returnValue = ''; };</script>$events"
  "/download" = "<!doctype html><meta charset=utf-8><title>download page</title><style>body{margin:0}#go{position:absolute;left:0;top:0;width:100%;height:100%;display:block;background:#e0e8f8;font:28px sans-serif}</style><a id=go href='/slow.bin' download='ardia-slow.bin'>download</a>$events"
}
while ($true) {
  if ($listener.Pending()) {
    $client = $listener.AcceptTcpClient()
    $keep = $false
    try {
      $client.ReceiveTimeout = 2000
      $stream = $client.GetStream()
      $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
      $request = $reader.ReadLine()
      while ($line = $reader.ReadLine()) { }
      $path = if ($request) { $request.Split(" ")[1] } else { "" }
      $route = $path -replace '\?.*$', ''
      if ($path) { Write-Log "request $path" }
      if ($route -eq "/slow.bin") {
        $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Disposition: attachment; filename=ardia-slow.bin`r`nContent-Length: 1073741824`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
        $stream.Write($head, 0, $head.Length)
        $stream.Flush()
        $slow.Add([pscustomobject]@{ Client = $client; Stream = $stream; Sent = 0; Opened = $clock.ElapsedMilliseconds })
        $keep = $true
        Write-Log "slow opened"
      } elseif ($route -like "/event/*") {
        Send-Text $stream "204 No Content" "text/plain" ""
      } elseif ($pages.ContainsKey($route)) {
        Send-Text $stream "200 OK" "text/html; charset=utf-8" $pages[$route]
      } else {
        Send-Text $stream "404 Not Found" "text/plain" ""
      }
    } catch { Write-Log "server error $($_.Exception.Message)" } finally { if (-not $keep) { $client.Close() } }
    continue
  }
  if ($clock.ElapsedMilliseconds -ge $nextDrip) {
    $nextDrip = $clock.ElapsedMilliseconds + 500
    foreach ($item in @($slow)) {
      try {
        $chunk = [byte[]]::new(8)
        $item.Stream.Write($chunk, 0, 8)
        $item.Stream.Flush()
        $item.Sent += 8
      } catch {
        Write-Log "slow closed after $($item.Sent) bytes and $($clock.ElapsedMilliseconds - $item.Opened) ms"
        try { $item.Client.Close() } catch { }
        [void]$slow.Remove($item)
      }
    }
  }
  Start-Sleep -Milliseconds 20
}
'@

if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) { throw "'$Setup' does not exist" }
if ((Test-Path -LiteralPath $entry) -or (Test-Path -LiteralPath $folder)) { throw "Ardia is already installed for this user" }
if (@(Ardia-Processes).Count) { throw "Ardia is already running" }
Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:ARDIA_BACKGROUND -ErrorAction SilentlyContinue
Remove-Item Env:ARDIA_DATA_DIR -ErrorAction SilentlyContinue

$server = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile", "-NonInteractive", "-File", "`"$serverScript`"", "-Port", $Port, "-Log", "`"$serverLog`"" -WindowStyle Hidden -PassThru
$serverBy = (Get-Date).AddSeconds(20)
$serverUp = $false
while (-not $serverUp -and (Get-Date) -lt $serverBy -and -not $server.HasExited) {
  $probe = New-Object System.Net.Sockets.TcpClient
  try { $serverUp = $probe.ConnectAsync("127.0.0.1", $Port).Wait(1000) -and $probe.Connected } catch { } finally { $probe.Dispose() }
  if (-not $serverUp) { Start-Sleep -Milliseconds 300 }
}
if (-not $serverUp) { throw "the test server never listened on port $Port" }

$install = Start-Process -FilePath (Resolve-Path -LiteralPath $Setup).Path -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "the installer exited with $($install.ExitCode)" }
Note "installed $Setup ($((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion))"
$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
Note "screen $($screen.Width)x$($screen.Height)"

try {
  New-Item -ItemType Directory -Force -Path $data | Out-Null
  Set-Content -LiteralPath (Join-Path $data "onboarding.json") -Value '{"completedAt":1700000000000,"version":1}' -Encoding utf8NoBOM
  $warmDir = Join-Path $Out "00-warm-up"
  New-Item -ItemType Directory -Force -Path $warmDir | Out-Null
  Start-Process -FilePath $exe -ArgumentList "--log-file=`"$(Join-Path $warmDir 'launch.log')`"" | Out-Null
  $warm = Wait-AppWindow 180
  if (-not $warm) { throw "warm-up: no app window within 180 s" }
  Note "warm-up: an app window in $([int]((Get-Date) - $started).TotalSeconds) s since the probe began"
  Start-Sleep -Seconds 20
  Save-Shot (Join-Path $warmDir "warm-up.png")
  $controlWatch = [Diagnostics.Stopwatch]::StartNew()
  [UnloadProbe.Native]::PostMessageW([IntPtr]([long]$warm.Handle), 0x0112, [IntPtr]0xF060, [IntPtr]::Zero) | Out-Null
  $warmDeadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $warmDeadline -and (Get-Process -Id ([int]$warm.ProcessId) -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 100 }
  Note "warm-up close: browser $(if (Get-Process -Id ([int]$warm.ProcessId) -ErrorAction SilentlyContinue) { 'still running after 60 s' } else { "gone in $([int]$controlWatch.ElapsedMilliseconds) ms" })"
  Stop-Ardia "after warm-up"
  Remove-Item -LiteralPath $seed -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $data -Destination $seed -Recurse -Force
  Remove-Item -LiteralPath (Join-Path $seed "Logs") -Recurse -Force -ErrorAction SilentlyContinue
  $seedFiles = @(Get-ChildItem -LiteralPath $seed -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Length)" })
  Note "seed profile top-level files: $($seedFiles -join ', ')"

  $index = 1
  foreach ($case in $Cases) {
    try { Run-Case $index $case }
    catch {
      Note "case $index $case failed in the probe: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
      Stop-Ardia "after a probe error in $case"
    }
    $index++
  }

  $events = @(Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $started } -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -in @("Application Error", "Windows Error Reporting", "Application Hang") -and $_.Message -match "Ardia\.exe" })
  Note "Application log Ardia crash or hang events: $($events.Count)"
  foreach ($event in $events | Select-Object -First 5) { Note "  $($event.TimeCreated.ToString('HH:mm:ss.fff')) $($event.ProviderName): $((($event.Message -split "`n") | Select-Object -First 3) -join ' | ')" }
} finally {
  Get-Process -Name Ardia -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
  $uninstaller = Join-Path $folder "unins000.exe"
  if (Test-Path -LiteralPath $uninstaller) { Start-Process -FilePath $uninstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait | Out-Null }
  $report = New-Object System.Collections.Generic.List[string]
  $report.Add("## Unload quit probe: $Label")
  $report.Add("")
  foreach ($line in $notes) { $report.Add("- $line") }
  $report.Add("")
  $report.Add("| case | old browser | user activation | download | old browser after close | app window after close | new windows after close | answered | quit log lines | beforeunload beacon | state at $CloseWatchSeconds s | relaunch pid | relaunch exit | relaunch window | state at $RelaunchWatchSeconds s | relaunch log lines |")
  $report.Add("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
  foreach ($row in $rows) {
    $report.Add("| $($row.Case) | $($row.OldBrowser) | $($row.Activation) | $(Escape-Cell $row.Download) | $(Escape-Cell $row.Old) | $(Escape-Cell $row.AppWindow) | $(Escape-Cell $row.NewWindows) | $(Escape-Cell $row.Answered) | $(Escape-Cell $row.KeyLines) | $(Escape-Cell $row.BeforeUnload) | $(Escape-Cell $row.EndState) | $($row.RelaunchPid) | $(Escape-Cell $row.RelaunchExit) | $(Escape-Cell $row.RelaunchWindow) | $(Escape-Cell $row.RelaunchEnd) | $(Escape-Cell $row.RelaunchKeyLines) |")
  }
  $report.Add("")
  foreach ($line in $details) { $report.Add($line) }
  $report | Set-Content -LiteralPath (Join-Path $Out "unload-probe.md")
  $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Out "unload-probe.json")
  if ($env:GITHUB_STEP_SUMMARY) { $report | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
}
