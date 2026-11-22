param(
    [ValidateSet('Restore', 'Source', 'Config', 'Open', 'Test')]
    [string]$Mode = 'Restore',
    [string]$BasePath,
    [string]$PlatformPath
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (!$PlatformPath) {
    $binFolders = foreach ($programFilesRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
        foreach ($product in '1cv8t', '1cv8') {
            Get-ChildItem -Path (Join-Path $programFilesRoot "$product\*\bin") -Directory -ErrorAction SilentlyContinue
        }
    }
    $PlatformPath = $binFolders |
        ForEach-Object {
            foreach ($exe in '1cv8t.exe', '1cv8.exe') {
                Get-Item -LiteralPath (Join-Path $_.FullName $exe) -ErrorAction SilentlyContinue
            }
        } |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (!$PlatformPath -or !(Test-Path -LiteralPath $PlatformPath -PathType Leaf)) {
    throw 'Платформа 1С не найдена. Укажите путь к 1cv8t.exe или 1cv8.exe через -PlatformPath.'
}
$logs = Join-Path ([IO.Path]::GetTempPath()) ('1c-sport-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($logs) | Out-Null
if ($Mode -eq 'Test') {
    if ($BasePath) { throw 'Режим Test создает собственную временную базу. Запустите его без -BasePath.' }
    $BasePath = Join-Path $logs 'Тестовая база'
}
if (!$BasePath) { $BasePath = Join-Path $root 'Локальная база' }
$base = [IO.Path]::GetFullPath($BasePath)
$dt = Join-Path $root 'Поставка\Спортивные мероприятия.dt'
$cf = Join-Path $root 'Поставка\Спортивные мероприятия.cf'
$src = Join-Path $root 'src'
$extensionName = 'УчетЯвки'
$extensionSource = Join-Path $root 'extension'
$cfe = Join-Path $root 'Поставка\Учет явки.cfe'
[Console]::WriteLine("Каталог базы: $base")

function Invoke-Platform([string]$arguments, [string]$step) {
    $log = Join-Path $logs "$step.log"
    $arguments += ' /Out "{0}" /DisableStartupDialogs /DisableStartupMessages' -f $log
    $process = Start-Process -FilePath $PlatformPath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        $detail = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
        throw "Шаг $step завершился с кодом $($process.ExitCode). $detail"
    }
}

function Invoke-Scenario([string]$command, [string]$step, [string]$expected, [string]$user) {
    $resultPath = Join-Path $logs "$step.txt"
    $arguments = 'ENTERPRISE /F "{0}" /C "{1}|{2}"' -f $base, $command, $resultPath
    if ($user) { $arguments += ' /N "{0}"' -f $user }
    Invoke-Platform $arguments $step
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8
    [Console]::WriteLine($result.TrimEnd())
    if ($result -notmatch $expected) { throw "Шаг ${step}: проверка не пройдена. Журнал: $resultPath" }
}

if ($Mode -eq 'Open') {
    if (!(Test-Path -LiteralPath (Join-Path $base '1Cv8.1CD'))) {
        throw 'Файловая база отсутствует. Сначала запустите режим Restore.'
    }
    Start-Process -FilePath $PlatformPath -ArgumentList ('ENTERPRISE /F "{0}"' -f $base)
    return
}

if ((Test-Path -LiteralPath $base) -and (Get-ChildItem -LiteralPath $base -Force | Select-Object -First 1)) {
    throw 'Каталог базы уже содержит файлы. Укажите новый каталог через -BasePath.'
}
[IO.Directory]::CreateDirectory($base) | Out-Null
Invoke-Platform ('CREATEINFOBASE File="{0}";' -f $base) 'create'

if ($Mode -in 'Restore','Test') {
    Invoke-Platform ('DESIGNER /F "{0}" /RestoreIB "{1}"' -f $base, $dt) 'restore'
} else {
    if ($Mode -eq 'Source') {
        Invoke-Platform ('DESIGNER /F "{0}" /LoadConfigFromFiles "{1}"' -f $base, $src) 'source'
    } else {
        Invoke-Platform ('DESIGNER /F "{0}" /LoadCfg "{1}"' -f $base, $cf) 'config'
    }
    Invoke-Platform ('DESIGNER /F "{0}" /UpdateDBCfg' -f $base) 'update'
    if ($Mode -eq 'Source') {
        Invoke-Platform ('DESIGNER /F "{0}" /LoadConfigFromFiles "{1}" -Extension {2}' -f $base, $extensionSource, $extensionName) 'extension-source'
    } else {
        Invoke-Platform ('DESIGNER /F "{0}" /LoadCfg "{1}" -Extension {2}' -f $base, $cfe, $extensionName) 'extension-config'
    }
    Invoke-Platform ('DESIGNER /F "{0}" /UpdateDBCfg -Extension {1}' -f $base, $extensionName) 'extension-update'
    $demoLog = Join-Path $logs 'demo-result.txt'
    Invoke-Platform ('ENTERPRISE /F "{0}" /C "СпортДемо|{1}"' -f $base, $demoLog) 'demo'
    $demoText = Get-Content -LiteralPath $demoLog -Raw -Encoding UTF8
    if ($demoText -notmatch '^Загружено:') { throw $demoText }
    [Console]::WriteLine($demoText.TrimEnd())
    Invoke-Scenario 'СпортДемоЯвки' 'attendance-demo' '^ИТОГ: ПРИМЕР ЯВКИ ГОТОВ'
    Invoke-Scenario 'СпортПользователи' 'demo-users' '^ИТОГ: ЧЕТЫРЕ УЧЕБНЫХ ПОЛЬЗОВАТЕЛЯ СОЗДАНЫ'
}

if ($Mode -eq 'Test') {
    Invoke-Scenario 'СпортТест' 'base-test' 'ИТОГ: ПРОЙДЕНО' 'Администратор'
    Invoke-Scenario 'СпортТестЯвки' 'attendance-test' '^ИТОГ: ПРОЙДЕНО' 'Администратор'
    foreach ($user in 'Администратор','Организатор','Судья','Читатель отчетов') {
        Invoke-Scenario 'СпортПрава' "rights-$user" '^ИТОГ: ПРОЙДЕНО' $user
    }
}
[Console]::WriteLine("Журналы: $logs")
