$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$working = Join-Path $env:RUNNER_TEMP 'atelie-windows-distribution'
$outer = Join-Path $working 'outer'
$application = Join-Path $working 'application'
$packager = Join-Path $working 'packager'
$output = Join-Path $working 'release'
foreach ($directory in @($working, $outer, $application, $packager, $output)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$portable = Join-Path $working 'base-portable.exe'
Invoke-WebRequest -Uri 'https://github.com/ubermaquinas825-coder/code.master/releases/download/v0.1.0-windows/Atelie-de-Arte-Windows-x64.exe' -OutFile $portable -TimeoutSec 180
$digest = (Get-FileHash $portable -Algorithm SHA256).Hash.ToLowerInvariant()
if ($digest -ne '43ead0da4375f7631928adac467b8fa6f848043c0f67c690187d6077accb36c1') { throw 'Base executable integrity check failed.' }

& 7z x -y "-o$outer" $portable
$embedded = Join-Path $outer '$PLUGINSDIR\app-64.7z'
& 7z x -y "-o$application" $embedded
$executable = Join-Path $application 'Atelie-de-Arte.exe'
# The NSIS ZIP reader does not consistently preserve UTF-8 executable names.
# Keep the visible product/shortcut name, and use an ASCII file name on disk.
Move-Item -LiteralPath (Join-Path $application 'Ateliê de Arte.exe') -Destination $executable
foreach ($required in @($executable, (Join-Path $application 'resources/app.asar'), (Join-Path $application 'resources/runtime/node.exe'), (Join-Path $application 'resources/server/dist/index.html'))) {
    if (!(Test-Path $required)) { throw ('Missing packaged component: ' + $required) }
}
$instructions = @'
ATELIÊ DE ARTE — WINDOWS 10/11 x64

INSTALADOR (recomendado): abra Atelie-de-Arte-Instalador-Windows-x64.exe e aguarde a instalação. Depois use o atalho Ateliê de Arte na área de trabalho ou no menu Iniciar.

PASTA COMPLETA: use Extrair Tudo no ZIP e abra Atelie-de-Arte.exe dentro da pasta extraída. Mantenha juntos o EXE, as DLLs e a pasta resources. Esta versão abre diretamente, sem descompactar o aplicativo novamente a cada uso.

Não precisa instalar Node.js, npm ou banco de dados, nem executar comandos. Seus projetos e arquivos ficam no seu usuário do Windows, separados do programa. No aplicativo, use Aplicativo > Abrir pasta dos meus dados.

OpenAI é opcional: Aplicativo > Configurar OpenAI. Não existe chave embutida. O pacote não tem assinatura digital comercial. Requisitos: Windows 10/11 de 64 bits e pelo menos 2 GB livres, além do espaço das imagens.
'@
$instructions | Set-Content (Join-Path $application 'LEIA-ME-PRIMEIRO.txt') -Encoding utf8
$instructions | Set-Content (Join-Path $output 'LEIA-ME.txt') -Encoding utf8

Copy-Item (Join-Path $repositoryRoot 'ci/windows-packager/package.json') (Join-Path $packager 'package.json')
Copy-Item (Join-Path $repositoryRoot 'ci/windows-packager/package-lock.json') (Join-Path $packager 'package-lock.json')
$config = Get-Content (Join-Path $repositoryRoot 'desktop/windows-installer-builder.json') -Raw | ConvertFrom-Json
$config.directories.output = $output
$config | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $packager 'builder.json') -Encoding utf8
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
Push-Location $packager
try {
    & npm ci --ignore-scripts --no-audit --no-fund
    & node 'node_modules/electron-builder/cli.js' --prepackaged $application --win nsis --x64 --publish never --config builder.json
} finally { Pop-Location }

$installer = Join-Path $output 'Atelie-de-Arte-Instalador-Windows-x64.exe'
if (!(Test-Path $installer)) { throw 'Installer was not generated.' }
Write-Host 'Installing in the current Windows user profile for the real startup test.'
$installation = Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
if (!$installation.WaitForExit(180000)) {
    Stop-Process -Id $installation.Id -Force -ErrorAction SilentlyContinue
    throw 'Installer did not complete within three minutes.'
}
$installation.Refresh()
if ($installation.ExitCode -ne 0) { throw ('Installer failed with exit code ' + $installation.ExitCode) }
$programs = Join-Path $env:LOCALAPPDATA 'Programs'
$installationDiagnostics = Join-Path $working 'diagnostics-installation'
New-Item -ItemType Directory -Path $installationDiagnostics -Force | Out-Null
$registry = @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -Like '*Ateli*' | Select-Object DisplayName,InstallLocation,DisplayIcon,UninstallString)
$candidates = @(Get-ChildItem $programs -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue | Where-Object FullName -Like '*Ateli*' | Select-Object FullName,Length)
$shortcutDirectories = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
$shortcuts = @()
$shell = New-Object -ComObject WScript.Shell
foreach ($directory in $shortcutDirectories) {
    foreach ($shortcut in @(Get-ChildItem $directory -Filter '*Ateli*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
        $target = $shell.CreateShortcut($shortcut.FullName)
        $shortcuts += @{ path = $shortcut.FullName; target = $target.TargetPath; targetExists = Test-Path -LiteralPath $target.TargetPath }
    }
}
@{ exitCode = $installation.ExitCode; registry = $registry; executableFiles = $candidates; shortcuts = $shortcuts } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $installationDiagnostics 'installation.json') -Encoding utf8
$candidates | Format-Table -AutoSize
$installed = Get-ChildItem $programs -Filter 'Atelie-de-Arte.exe' -File -Recurse | Select-Object -First 1
if (!$installed) { throw 'Installed application executable was not found.' }
if (!@($shortcuts | Where-Object { $_.target -eq $installed.FullName -and $_.targetExists }).Count) { throw 'A working application shortcut was not created.' }
& pwsh -NoProfile -File (Join-Path $repositoryRoot 'ci/windows-app-smoke.ps1') -LaunchPath $installed.FullName -DiagnosticsDirectory (Join-Path $working 'diagnostics-installed') -DebugPort 9223
if ($LASTEXITCODE -ne 0) { throw 'The installed application failed its native startup test.' }

$zip = Join-Path $output 'Atelie-de-Arte-Windows-Pasta-Completa.zip'
& 7z a -tzip -mx=5 '-mmt=on' $zip (Join-Path $application '*')
& 7z t $zip
$complete = Join-Path $working 'complete-from-zip'
& 7z x -y "-o$complete" $zip
& pwsh -NoProfile -File (Join-Path $repositoryRoot 'ci/windows-app-smoke.ps1') -LaunchPath (Join-Path $complete 'Atelie-de-Arte.exe') -DiagnosticsDirectory (Join-Path $working 'diagnostics-folder') -DebugPort 9222
if ($LASTEXITCODE -ne 0) { throw 'The actual complete ZIP failed its native startup test.' }
foreach ($file in @($installer, $zip)) {
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
    ($hash + '  ' + (Split-Path $file -Leaf)) | Set-Content ($file + '.sha256') -Encoding ascii
}
$folderReport = Get-Content (Join-Path $working 'diagnostics-folder/report.json') -Raw | ConvertFrom-Json
$installedReport = Get-Content (Join-Path $working 'diagnostics-installed/report.json') -Raw | ConvertFrom-Json
$report = [ordered]@{
    status = 'passed'; checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    packagingVersion = '0.1.1'; baseExecutableSha256 = $digest
    windows = (Get-CimInstance Win32_OperatingSystem).Caption
    folderReadyInSeconds = $folderReport.readyInSeconds
    installedReadyInSeconds = $installedReport.readyInSeconds
    repeatedLaunchValidated = $true
    files = @((Get-Item $installer), (Get-Item $zip)) | ForEach-Object { @{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
}
$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $output 'windows-startup-validation.json') -Encoding utf8
@'
Atualização da distribuição Windows para eliminar a extração silenciosa em cada abertura.

Baixe Atelie-de-Arte-Instalador-Windows-x64.exe, instale e abra pelo atalho Ateliê de Arte. A alternativa Atelie-de-Arte-Windows-Pasta-Completa.zip contém todo o aplicativo: use Extrair Tudo e abra Atelie-de-Arte.exe dentro da pasta.

Os dois modos foram abertos nativamente no Windows, com janela, interface, backend e segunda abertura verificados antes da publicação. As funcionalidades do sistema permanecem as da versão 0.1.0; esta revisão altera a distribuição Windows.

Windows 10/11 x64. Sem instalação manual de Node.js ou comandos. Pelo menos 2 GB livres. Pacote sem assinatura digital comercial. Os dados ficam no perfil do usuário; OpenAI é opcional.
'@ | Set-Content (Join-Path $output 'release-notes.md') -Encoding utf8
$report | ConvertTo-Json -Depth 10
