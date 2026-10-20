$ErrorActionPreference = 'Stop'
$startedAt = Get-Date
$diagnosticDirectory = Join-Path $env:RUNNER_TEMP 'atelie-windows-startup'
New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
$exePath = Join-Path $diagnosticDirectory 'Atelie-de-Arte-Windows-x64.exe'
$report = [ordered]@{ startedAt = $startedAt.ToUniversalTime().ToString('o'); status = 'failed'; error = $null; checks = @(); snapshots = @() }
$ownedIds = [System.Collections.Generic.HashSet[int]]::new()
$process = $null
$success = $false
$debugPort = 9222

function Get-AppSnapshot {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    do {
        $added = $false
        foreach ($item in $all) {
            if ($ownedIds.Contains([int]$item.ParentProcessId) -and !$ownedIds.Contains([int]$item.ProcessId)) {
                [void]$ownedIds.Add([int]$item.ProcessId)
                $added = $true
            }
        }
    } while ($added)
    foreach ($item in $all) {
        if ($item.Name -like 'Ateli*' -or ($item.Name -eq 'node.exe' -and $item.CommandLine -match 'resources[\\/]server[\\/]build[\\/]server[\\/]index.js')) {
            [void]$ownedIds.Add([int]$item.ProcessId)
        }
    }
    return @($all | Where-Object { $ownedIds.Contains([int]$_.ProcessId) } | ForEach-Object {
        $native = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        [ordered]@{ id = $_.ProcessId; parentId = $_.ParentProcessId; name = $_.Name; executable = $_.ExecutablePath; commandLine = $_.CommandLine;
            windowTitle = $native.MainWindowTitle; windowHandle = if ($native) { $native.MainWindowHandle.ToInt64() } else { 0 } }
    })
}

function Invoke-PageEvaluation([string]$webSocketUrl) {
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $timeout = [System.Threading.CancellationTokenSource]::new(8000)
    try {
        $socket.ConnectAsync([Uri]$webSocketUrl, $timeout.Token).GetAwaiter().GetResult()
        $expression = '({url:location.href,title:document.title,ready:document.readyState,visible:document.visibilityState,text:document.body.innerText.slice(0,4000),headings:[...document.querySelectorAll("h1,h2")].map(e=>e.innerText),nodeAccess:typeof window.require})'
        $request = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $expression; returnByValue = $true } } | ConvertTo-Json -Depth 8 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($request)
        $socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        while ($true) {
            $stream = [IO.MemoryStream]::new()
            try {
                do {
                    $message = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $timeout.Token).GetAwaiter().GetResult()
                    if ($message.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'CDP socket closed.' }
                    $stream.Write($buffer, 0, $message.Count)
                } while (!$message.EndOfMessage)
                $response = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            } finally { $stream.Dispose() }
            if ($response.id -eq 1) {
                if ($response.error -or $response.result.exceptionDetails) { throw ($response | ConvertTo-Json -Depth 10 -Compress) }
                return $response.result.result.value
            }
        }
    } finally { $socket.Dispose(); $timeout.Dispose() }
}

function Save-DesktopImage {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
            $bitmap.Save((Join-Path $diagnosticDirectory 'desktop.png'), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    } catch { $_.ToString() | Set-Content (Join-Path $diagnosticDirectory 'screenshot-unavailable.txt') }
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $report.os = [ordered]@{ caption = $os.Caption; version = $os.Version; architecture = $os.OSArchitecture; freeMemoryKB = $os.FreePhysicalMemory; is64Bit = [Environment]::Is64BitOperatingSystem; tempDirectory = $env:TEMP }
    Write-Host ('Downloading published Windows executable to ' + $exePath)
    Invoke-WebRequest -Uri 'https://github.com/ubermaquinas825-coder/code.master/releases/download/v0.1.0-windows/Atelie-de-Arte-Windows-x64.exe' -OutFile $exePath -TimeoutSec 180
    $digest = (Get-FileHash $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $report.exeSha256 = $digest
    if ($digest -ne '43ead0da4375f7631928adac467b8fa6f848043c0f67c690187d6077accb36c1') { throw 'Published executable SHA-256 does not match.' }
    $report.checks += 'Downloaded EXE matches original SHA-256'
    $arguments = @('--remote-debugging-port=9222', '--enable-logging', ('--log-file=' + (Join-Path $diagnosticDirectory 'electron.log')))
    Write-Host 'Starting the actual NSIS portable executable (not developer sources).'
    $process = Start-Process -FilePath $exePath -ArgumentList $arguments -PassThru
    [void]$ownedIds.Add($process.Id)
    $launchTime = Get-Date
    $nextProgress = 0
    $page = $null
    while (((Get-Date) - $launchTime).TotalSeconds -lt 120) {
        $elapsed = [int]((Get-Date) - $launchTime).TotalSeconds
        $snapshot = @(Get-AppSnapshot)
        if ($elapsed -ge $nextProgress) {
            Write-Host ('Elapsed ' + $elapsed + ' seconds; owned app processes: ' + $snapshot.Count)
            $report.snapshots += [ordered]@{ elapsedSeconds = $elapsed; processes = $snapshot }
            $nextProgress += 15
        }
        try {
            $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$debugPort/json/list" -TimeoutSec 2)
            $targets | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $diagnosticDirectory 'cdp-targets.json')
            $page = $targets | Where-Object { $_.type -eq 'page' -and $_.url -match '^http://127\.0\.0\.1:\d+/app' } | Select-Object -First 1
            $nativeWindow = $snapshot | Where-Object { $_.windowHandle -ne 0 } | Select-Object -First 1
            if ($page -and $nativeWindow) {
                $dom = Invoke-PageEvaluation $page.webSocketDebuggerUrl
                if ($dom.ready -eq 'complete' -and $dom.text.Length -gt 80) {
                    $report.dom = $dom
                    $report.nativeWindow = $nativeWindow
                    $origin = ([Uri]$page.url).GetLeftPart([UriPartial]::Authority)
                    $report.backend = Invoke-RestMethod -Uri ($origin + '/api/config') -TimeoutSec 5
                    if ($report.backend.appName -ne 'Ateliê de Arte') { throw 'Local API returned the wrong application.' }
                    if ($dom.nodeAccess -ne 'undefined') { throw 'The renderer unexpectedly exposes Node.' }
                    $report.checks += 'Real native Windows window has a nonzero MainWindowHandle'
                    $report.checks += 'Real frontend URL and DOM rendered in the packaged Electron process'
                    $report.checks += 'Bundled Windows Node backend API responds'
                    $report.checks += 'Renderer isolated from Node'
                    $success = $true
                    break
                }
            }
        } catch { $report.lastPollingError = $_.ToString() }
        Start-Sleep -Milliseconds 750
    }
    if (!$success) { throw 'The portable application did not expose a visible native window and loaded frontend within 120 seconds.' }
    $report.status = 'passed'
} catch {
    $report.error = $_.ToString()
    Write-Host ('STARTUP FAILURE: ' + $report.error)
} finally {
    $report.finalProcesses = @(Get-AppSnapshot)
    Save-DesktopImage
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        $ui = @()
        foreach ($window in $windows) {
            if ($ownedIds.Contains([int]$window.Current.ProcessId)) {
                $names = @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Select-Object -First 120 | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
                $ui += [ordered]@{ pid = $window.Current.ProcessId; title = $window.Current.Name; controls = $names }
            }
        }
        $ui | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $diagnosticDirectory 'windows-ui.json')
    } catch { $_.ToString() | Set-Content (Join-Path $diagnosticDirectory 'ui-automation-unavailable.txt') }
    try {
        $appDirectories = @(Get-ChildItem $env:APPDATA -Directory -ErrorAction SilentlyContinue | Where-Object Name -Like '*ateli*')
        foreach ($directory in $appDirectories) {
            $log = Join-Path $directory.FullName 'app.log'
            if (Test-Path $log) { (Get-Content $log -Raw) -replace 'sk-[A-Za-z0-9_-]{12,}', '[redacted]' | Set-Content (Join-Path $diagnosticDirectory 'backend-app.log') }
        }
    } catch { $_.ToString() | Set-Content (Join-Path $diagnosticDirectory 'app-log-copy-error.txt') }
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $startedAt.AddMinutes(-1) } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'Ateli|Electron|node\.exe|nsi.*\.tmp' } | Select-Object -First 15 TimeCreated,Id,ProviderName,Message |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $diagnosticDirectory 'application-events.json')
    } catch { $_.ToString() | Set-Content (Join-Path $diagnosticDirectory 'event-log-unavailable.txt') }
    $report.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    $report | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $diagnosticDirectory 'report.json')
    Write-Host ('Diagnostic artifacts: ' + $diagnosticDirectory)
    $report | ConvertTo-Json -Depth 12
    foreach ($id in @($ownedIds)) {
        $appProcess = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($appProcess -and $appProcess.MainWindowHandle -ne 0) { [void]$appProcess.CloseMainWindow() }
    }
    Start-Sleep -Seconds 3
    foreach ($id in @($ownedIds)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}
if ($success) { exit 0 } else { exit 1 }
