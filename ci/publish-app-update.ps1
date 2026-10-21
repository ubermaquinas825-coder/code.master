param(
    [Parameter(Mandatory = $true)][string]$PayloadDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PatchSha256,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$PayloadCommit
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (![OperatingSystem]::IsWindows()) { throw 'This script requires native Windows.' }
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$working = Join-Path $env:RUNNER_TEMP 'atelie-windows-update'
$application = Join-Path $working 'application'
$patchStage = Join-Path $working 'verified-patch'
$packager = Join-Path $working 'packager'
$output = Join-Path $working 'release'
$baseUrl = 'https://github.com/ubermaquinas825-coder/code.master/releases/download/v0.1.1-windows/Atelie-de-Arte-Windows-Pasta-Completa.zip'
$baseSha256 = 'c2ee7e6e2dea92259e6a69e5bf3335b30eb9c69e25c3a79b80969547ba6084a9'
if (Test-Path $working) { Remove-Item -LiteralPath $working -Recurse -Force }
foreach ($directory in @($application, $patchStage, $packager, $output)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$patch = Join-Path $PayloadDirectory 'windows-update.zip'
$manifest = Get-Content -LiteralPath (Join-Path $PayloadDirectory 'windows-update-manifest.json') -Raw | ConvertFrom-Json
$expectedPatch = $PatchSha256.ToLowerInvariant()
if ($manifest.schemaVersion -ne 1 -or $manifest.version -ne '0.2.0' -or $manifest.platform -ne 'win32' -or $manifest.arch -ne 'x64') { throw 'Unexpected update manifest.' }
if ($manifest.base.url -cne $baseUrl -or $manifest.base.sha256 -cne $baseSha256 -or $manifest.base.version -ne '0.1.1') { throw 'Unexpected base distribution.' }
if ($manifest.runtime.node -ne '24.18.0' -or $manifest.runtime.electron -ne '44.9.1' -or $manifest.runtime.reuseDependenciesFromBase -ne $true) { throw 'Unexpected runtime contract.' }
if ($manifest.patch.filename -cne 'windows-update.zip' -or $manifest.patch.sha256 -cne $expectedPatch) { throw 'Manifest does not match the dispatched patch SHA-256.' }
$patchItem = Get-Item -LiteralPath $patch
if ($patchItem.Length -ne $manifest.patch.bytes -or $patchItem.Length -gt 50MB) { throw 'Patch length is invalid.' }
if ((Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedPatch) { throw 'Patch integrity check failed.' }

function Test-AllowedPatchPath([string]$Path) {
    if ($Path -match '(?:^|/)(?:\.[^/]+|node_modules|tests?|uploads?|keys?|secrets?|credentials?|provider-settings\.json|app\.sqlite(?:-wal|-shm)?)(?:/|$)') { return $false }
    return ($Path -cmatch '^resources/app\.asar$' -or
        $Path -cmatch '^resources/server/package(?:-lock)?\.json$' -or
        $Path -cmatch '^resources/server/build/(?:server|shared)/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.js$' -or
        $Path -cmatch '^resources/server/dist/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_.-]+\.(?:html|js|css|svg|png|jpe?g|webp|ico|woff2?)$')
}
$fileMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $manifest.files) {
    if (!(Test-AllowedPatchPath $file.path) -or $file.path.Length -gt 260 -or $file.path -match '\\|\.\.' -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $file.bytes -lt 1 -or $file.bytes -gt 50MB) { throw ('Disallowed manifest entry: ' + $file.path) }
    if (!$fileMap.TryAdd($file.path, $file)) { throw ('Duplicate manifest path: ' + $file.path) }
}
foreach ($required in @('resources/app.asar', 'resources/server/package.json', 'resources/server/package-lock.json', 'resources/server/build/server/index.js', 'resources/server/dist/index.html')) {
    if (!$fileMap.ContainsKey($required)) { throw ('Missing mandatory update file: ' + $required) }
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$archive = [IO.Compression.ZipFile]::OpenRead($patch)
try {
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName
        if (!(Test-AllowedPatchPath $name) -or !$fileMap.ContainsKey($name) -or !$seen.Add($name)) { throw ('ZIP entry is not uniquely allowlisted: ' + $name) }
        $expected = $fileMap[$name]
        if ($entry.Length -ne $expected.bytes) { throw ('ZIP entry length mismatch: ' + $name) }
        $destination = Join-Path $patchStage $name
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        $inputStream = $entry.Open()
        $outputStream = [IO.File]::Create($destination)
        try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected.sha256) { throw ('Patched file hash mismatch: ' + $name) }
    }
} finally { $archive.Dispose() }
if ($seen.Count -ne $fileMap.Count) { throw 'The patch is missing files from its manifest.' }

$base = Join-Path $working 'base-v0.1.1.zip'
Invoke-WebRequest -Uri $baseUrl -OutFile $base -TimeoutSec 300
if ((Get-FileHash -LiteralPath $base -Algorithm SHA256).Hash.ToLowerInvariant() -cne $baseSha256) { throw 'Base distribution integrity check failed.' }
& 7z t $base
& 7z x -y "-o$application" $base
$executable = Join-Path $application 'Atelie-de-Arte.exe'
foreach ($required in @($executable, (Join-Path $application 'resources/runtime/node.exe'), (Join-Path $application 'resources/server/node_modules/sharp/package.json'))) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) { throw ('Missing component in the pinned base: ' + $required) }
}
function Get-DependencyContract($Dependencies) {
    return (($Dependencies.PSObject.Properties | Sort-Object Name | ForEach-Object { $_.Name + '=' + [string]$_.Value }) -join "`n")
}
$basePackage = Get-Content (Join-Path $application 'resources/server/package.json') -Raw | ConvertFrom-Json
if ((Get-DependencyContract $basePackage.dependencies) -cne (Get-DependencyContract $manifest.productionDependencies)) { throw 'Production dependencies changed; a code-only update cannot reuse this base.' }
if ((& (Join-Path $application 'resources/runtime/node.exe') --version) -ne 'v24.18.0') { throw 'Unexpected bundled Node runtime.' }
# Replace the entire compiled trees so old hashed frontend assets and stale
# backend modules cannot survive the update. Dependencies stay in their base tree.
foreach ($tree in @('build', 'dist')) { Remove-Item -LiteralPath (Join-Path $application "resources/server/$tree") -Recurse -Force }
foreach ($file in $manifest.files) {
    $destination = Join-Path $application $file.path
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $patchStage $file.path) -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw ('Overlay verification failed: ' + $file.path) }
}
$newPackage = Get-Content (Join-Path $application 'resources/server/package.json') -Raw | ConvertFrom-Json
$newLock = Get-Content (Join-Path $application 'resources/server/package-lock.json') -Raw | ConvertFrom-Json
if ($newPackage.version -ne '0.2.0' -or $newLock.version -ne '0.2.0' -or $newLock.packages.''.version -ne '0.2.0') { throw 'Server version metadata was not updated.' }
if ((Get-DependencyContract $newPackage.dependencies) -cne (Get-DependencyContract $basePackage.dependencies)) { throw 'Overlay changed production dependencies.' }
if ((Get-DependencyContract $newLock.packages.''.dependencies) -cne (Get-DependencyContract $newPackage.dependencies)) { throw 'Overlay package and lock disagree.' }

$instructions = @'
ATELIÊ DE ARTE 0.2.0 — WINDOWS x64

INSTALADOR: abra Atelie-de-Arte-Instalador-Windows-x64.exe, aguarde e use o atalho Ateliê de Arte na área de trabalho ou no menu Iniciar.

PASTA COMPLETA: use Extrair Tudo no ZIP e abra Atelie-de-Arte.exe dentro da pasta extraída. Mantenha o EXE, as DLLs e resources juntos. Não precisa instalar Node.js, npm ou banco de dados.

A versão 0.2.0 inclui análise local de contraste, regiões persistentes, edição PNG com máscara e borracha, transformações e vetorização local da arte editada. A análise local é uma estimativa de contraste; revise as caixas. O processamento usa o computador local; não promete aceleração por GPU nem detecção semântica perfeita.

OpenAI é opcional e requer internet e sua própria chave. Configure a chave, o modelo de imagem e o modelo de análise em Aplicativo > Configurar OpenAI. Nenhuma chave é distribuída. A chave é protegida pelo usuário do Windows. Seus projetos ficam no perfil do usuário; use Aplicativo > Abrir pasta dos meus dados para localizar o backup com o aplicativo fechado.

Requisito de plataforma: Windows 10/11 x64; reserve pelo menos 2 GB livres além das imagens. A validação automatizada desta distribuição roda no Windows Server 2025 do GitHub Actions. Ela não substitui teste em seu notebook Windows 10/11. O pacote não tem assinatura digital comercial.
'@
$instructions | Set-Content (Join-Path $application 'LEIA-ME-PRIMEIRO.txt') -Encoding utf8
$instructions | Set-Content (Join-Path $output 'LEIA-ME.txt') -Encoding utf8

# Use the existing pinned packager lock, changing only temporary root metadata.
foreach ($name in @('package.json', 'package-lock.json')) {
    $metadata = Get-Content (Join-Path $repositoryRoot "ci/windows-packager/$name") -Raw | ConvertFrom-Json -AsHashtable
    $metadata['version'] = '0.2.0'
    if ($metadata.ContainsKey('packages')) { $metadata['packages']['']['version'] = '0.2.0' }
    $metadata | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $packager $name) -Encoding utf8
}
$config = Get-Content (Join-Path $repositoryRoot 'desktop/windows-installer-builder.json') -Raw | ConvertFrom-Json
if ($config.win.executableName -cne 'Atelie-de-Arte' -or $config.nsis.useZip -ne $true -or $config.nsis.differentialPackage -ne $false -or $config.nsis.shortcutName -cne 'Ateliê de Arte') { throw 'Unexpected installer configuration.' }
$config.directories.output = $output
$config | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $packager 'builder.json') -Encoding utf8
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
Push-Location $packager
try {
    & npm ci --ignore-scripts --no-audit --no-fund
    $asarCheck = @'
const assert = require('node:assert/strict');
const asar = require('@electron/asar');
const archive = process.argv[1];
const expected = ['main.cjs','runtime.cjs','settings.cjs','settings-preload.cjs','settings-store.cjs','settings.html','assets/icon.png','package.json'];
assert.deepEqual(asar.listPackage(archive).map(p => p.replaceAll('\\','/').replace(/^\//,'')).filter(p => p !== 'assets').sort(), expected.sort());
const metadata = JSON.parse(asar.extractFile(archive, 'package.json'));
assert.equal(metadata.version, '0.2.0');
assert.equal(metadata.devDependencies.electron, '44.9.1');
for (const name of expected.filter(name => /\.(cjs|json|html)$/.test(name))) {
  assert.ok(!/sk-[A-Za-z0-9_-]{20,}|-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----/.test(asar.extractFile(archive, name).toString()), 'Possible embedded secret');
}
'@
    & node -e $asarCheck (Join-Path $application 'resources/app.asar')
    & node 'node_modules/electron-builder/cli.js' --prepackaged $application --win nsis --x64 --publish never --config builder.json
} finally { Pop-Location }
$installer = Join-Path $output 'Atelie-de-Arte-Instalador-Windows-x64.exe'
if (!(Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Installer was not generated.' }
Write-Host 'Installing the actual release EXE in the current Windows user profile.'
$installation = Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
if (!$installation.WaitForExit(180000)) {
    Stop-Process -Id $installation.Id -Force -ErrorAction SilentlyContinue
    throw 'Installation exceeded 180 seconds.'
}
$installation.Refresh()
if ($installation.ExitCode -ne 0) { throw ('Installer failed with exit code ' + $installation.ExitCode) }
$programs = Join-Path $env:LOCALAPPDATA 'Programs'
$candidates = @(Get-ChildItem -LiteralPath $programs -Filter 'Atelie-de-Arte.exe' -File -Recurse)
if ($candidates.Count -ne 1) { throw ('Expected one installed application; found ' + $candidates.Count) }
$installed = $candidates[0]
if ((Get-FileHash (Join-Path $installed.DirectoryName 'resources/app.asar') -Algorithm SHA256).Hash -ne (Get-FileHash (Join-Path $application 'resources/app.asar') -Algorithm SHA256).Hash) { throw 'Installed shell does not match the update payload.' }
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$shortcuts = @(Get-ChildItem -LiteralPath $desktop -Filter '*Ateli*.lnk' -File | ForEach-Object {
    $shortcut = $shell.CreateShortcut($_.FullName)
    $targetExists = $false
    if ($shortcut.TargetPath) { $targetExists = Test-Path -LiteralPath $shortcut.TargetPath -PathType Leaf }
    [ordered]@{ path = $_.FullName; target = $shortcut.TargetPath; targetExists = $targetExists }
})
if (!@($shortcuts | Where-Object { $_.target -eq $installed.FullName -and $_.targetExists }).Count) { throw 'A real working Desktop shortcut to the installed EXE was not created.' }
$installationDiagnostics = Join-Path $working 'diagnostics-installation'
New-Item -ItemType Directory -Path $installationDiagnostics -Force | Out-Null
@{ exitCode = $installation.ExitCode; installedExecutable = $installed.FullName; desktopShortcuts = $shortcuts } |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $installationDiagnostics 'installation.json') -Encoding utf8
& pwsh -NoProfile -File (Join-Path $repositoryRoot 'ci/windows-app-smoke.ps1') -LaunchPath $installed.FullName -DiagnosticsDirectory (Join-Path $working 'diagnostics-installed') -DebugPort 9223
if ($LASTEXITCODE -ne 0) { throw 'Installed application startup verification failed.' }

$zip = Join-Path $output 'Atelie-de-Arte-Windows-Pasta-Completa.zip'
& 7z a -tzip -mx=5 '-mmt=on' $zip (Join-Path $application '*')
& 7z t $zip
$complete = Join-Path $working 'complete-from-final-zip'
& 7z x -y "-o$complete" $zip
foreach ($file in $manifest.files) {
    if ((Get-FileHash -LiteralPath (Join-Path $complete $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw ('Final ZIP payload mismatch: ' + $file.path) }
}
& pwsh -NoProfile -File (Join-Path $repositoryRoot 'ci/windows-app-smoke.ps1') -LaunchPath (Join-Path $complete 'Atelie-de-Arte.exe') -DiagnosticsDirectory (Join-Path $working 'diagnostics-folder') -DebugPort 9222
if ($LASTEXITCODE -ne 0) { throw 'Final complete ZIP startup verification failed.' }
& pwsh -NoProfile -File (Join-Path $repositoryRoot 'ci/windows-feature-smoke.ps1') -ApplicationDirectory $complete -DiagnosticsDirectory (Join-Path $working 'diagnostics-features')
if ($LASTEXITCODE -ne 0) { throw 'Final complete ZIP feature verification failed.' }
foreach ($file in @($installer, $zip)) {
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    ($hash + '  ' + (Split-Path $file -Leaf)) | Set-Content ($file + '.sha256') -Encoding ascii
}
$folderReport = Get-Content (Join-Path $working 'diagnostics-folder/report.json') -Raw | ConvertFrom-Json
$installedReport = Get-Content (Join-Path $working 'diagnostics-installed/report.json') -Raw | ConvertFrom-Json
$featureReport = Get-Content (Join-Path $working 'diagnostics-features/feature-report.json') -Raw | ConvertFrom-Json
if ($folderReport.status -ne 'passed' -or $installedReport.status -ne 'passed' -or $featureReport.status -ne 'passed' -or $folderReport.doubleLaunchRequested -ne $true -or $installedReport.doubleLaunchRequested -ne $true) { throw 'All native checks, including both repeated launches, must pass before publication.' }
$report = [ordered]@{
    status = 'passed'; checkedAt = (Get-Date).ToUniversalTime().ToString('o'); version = '0.2.0'
    payloadCommit = $PayloadCommit; patchSha256 = $expectedPatch; baseZipSha256 = $baseSha256
    windows = (Get-CimInstance Win32_OperatingSystem).Caption
    windowsVersion = (Get-CimInstance Win32_OperatingSystem).Version
    node = '24.18.0'; electron = '44.9.1'; signed = $false
    folderReadyInSeconds = $folderReport.readyInSeconds; installedReadyInSeconds = $installedReport.readyInSeconds
    installedDesktopShortcutValidated = $true; repeatedLaunchValidated = $true; finalZipCrcValidated = $true
    localFeatureChecks = $featureReport.checks
    validationScope = 'Native GitHub Actions Windows Server 2025; no Windows 10/11 notebook test claimed.'
    files = @((Get-Item $installer), (Get-Item $zip)) | ForEach-Object { @{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
}
$report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $output 'windows-update-validation.json') -Encoding utf8
@'
Ateliê de Arte 0.2.0: extrator com análise local de contraste, regiões persistentes, editor PNG com máscara/borracha e transformações, histórico de versões e vetorização real da arte editada. Recursos locais usam o computador; não há promessa de GPU ou reconhecimento perfeito de desenhos.

Baixe o instalador, instale e abra pelo atalho Ateliê de Arte. Como alternativa, extraia toda a pasta do ZIP e abra Atelie-de-Arte.exe. Não precisa instalar Node.js ou executar comandos.

Antes de publicar, esta distribuição passou no Windows Server 2025 do GitHub Actions: instalação por usuário, atalho real na área de trabalho, janela/interface/backend, segunda abertura de ambos os formatos e funcionalidades locais da distribuição final (upload, análise, fila, recorte, alfa, edição, paths SVG e persistência após reinício). Não foi realizado teste em notebook Windows 10/11.

OpenAI é opcional. Configure sua própria chave e os modelos em Aplicativo > Configurar OpenAI. Não há chave no pacote. Os dados ficam no perfil do usuário. Windows 10/11 x64; ao menos 2 GB livres além das imagens. Distribuição sem assinatura digital comercial.
'@ | Set-Content (Join-Path $output 'release-notes.md') -Encoding utf8
$report | ConvertTo-Json -Depth 12
