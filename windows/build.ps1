<#
.SYNOPSIS
    Rest 的 Windows 构建脚本（对应 macOS 的 macos/build.sh）。

.DESCRIPTION
    需要在装了 .NET 8 SDK 的 Windows 上运行。参数：
      -Configuration Release   默认 Debug
      -Test                    先跑核心逻辑单元测试
      -Zip                     打出 dist/Rest-<版本>-win-x64-portable.zip（免安装）
      -Installer               打出 dist/Rest-<版本>-win-x64-setup.exe（需要 Inno Setup 6）
      -SelfTest                构建后跑一次无界面自检（会打印到当前控制台）
      -Preview                 构建后直接启动并弹一次休息界面
      -Version 1.2.3           覆盖版本号；默认读仓库根的 VERSION 文件

.EXAMPLE
    .\build.ps1 -Configuration Release -Test -Zip -Installer

.NOTES
    安装器编译需要 Inno Setup 6：
      winget install JRSoftware.InnoSetup
#>
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$Test,
    [switch]$Zip,
    [switch]$Installer,
    [switch]$SelfTest,
    [switch]$Preview,
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
# 日志里不要 Compress-Archive 的进度条（不加会一条条刷进度，CI 日志几万行）
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$appProject = Join-Path $root 'src/Rest.App/Rest.App.csproj'
$testProject = Join-Path $root 'tests/Rest.Core.Tests/Rest.Core.Tests.csproj'
$outDir = Join-Path $root "dist/win-x64"

# 版本号只有一份：仓库根的 VERSION。CI 打 tag 时用 tag 名覆盖（v1.2.3）。
if (-not $Version) {
    $versionFile = Join-Path (Split-Path -Parent $root) 'VERSION'
    if (Test-Path $versionFile) { $Version = (Get-Content $versionFile -Raw).Trim() }
}
$Version = $Version -replace '^v', ''
if (-not $Version) { $Version = '0.0.0' }

Write-Host "== 环境 ==" -ForegroundColor Cyan
dotnet --version
Write-Host "版本号 $Version"

if ($Test) {
    Write-Host "== 单元测试（节奏模型）==" -ForegroundColor Cyan
    dotnet test $testProject -c $Configuration --nologo
    if ($LASTEXITCODE -ne 0) { throw "测试失败" }
}

Write-Host "== 发布 $Configuration / win-x64 ==" -ForegroundColor Cyan
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }

dotnet publish $appProject `
    -c $Configuration `
    -r win-x64 `
    --self-contained true `
    -p:PublishReadyToRun=false `
    -p:Version=$Version `
    -o $outDir

if ($LASTEXITCODE -ne 0) { throw "发布失败" }

$exe = Join-Path $outDir 'Rest.exe'
if (-not (Test-Path $exe)) { throw "产物里没有 Rest.exe" }

Write-Host "产物：$exe" -ForegroundColor Green

$distDir = Join-Path $root 'dist'
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }

# 有证书就签，没有就跳过。SmartScreen / 智能应用控制只认受信任的签名，
# 自签名和「不签」在陌生机器上是同一个结果，所以这里不做自签名兜底。
function Sign-Artifact([string]$Path) {
    $pfx = $env:WINDOWS_SIGN_PFX_BASE64
    if (-not $pfx) { return }
    $signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
    if (-not $signtool) {
        # Windows SDK 装了就有，但不在 PATH 里
        $signtool = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin') `
            -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
            Where-Object FullName -like '*x64*' |
            Sort-Object FullName -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $signtool) { throw "配了 WINDOWS_SIGN_PFX_BASE64 但找不到 signtool.exe（装 Windows SDK）" }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rest-sign-" + [guid]::NewGuid() + ".pfx")
    try {
        [System.IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($pfx))
        & $signtool sign /f $tmp /p $env:WINDOWS_SIGN_PFX_PASS `
            /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $Path
        if ($LASTEXITCODE -ne 0) { throw "签名失败：$Path" }
        Write-Host "已签名：$Path" -ForegroundColor Green
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

Sign-Artifact $exe

if ($Zip) {
    $zipPath = Join-Path $distDir "Rest-$Version-win-x64-portable.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath
    Write-Host "便携包：$zipPath" -ForegroundColor Green
}

if ($Installer) {
    Write-Host "== 生成安装器 ==" -ForegroundColor Cyan
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
        )
        $iscc = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if (-not $iscc) {
        throw "找不到 ISCC.exe（Inno Setup）。装一个：winget install JRSoftware.InnoSetup"
    }

    # 输出目录显式钉在 windows/dist，不依赖 .iss 里的 OutputDir
    & $iscc "/DAppVersion=$Version" "/O$distDir" (Join-Path $root 'installer/Rest.iss')
    if ($LASTEXITCODE -ne 0) { throw "安装器编译失败（ISCC exit=$LASTEXITCODE）" }

    $setup = Join-Path $distDir "Rest-$Version-win-x64-setup.exe"
    if (-not (Test-Path $setup)) { throw "没生成 $setup" }
    Sign-Artifact $setup
    Write-Host "安装器：$setup（$([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB）" -ForegroundColor Green
}

if ($SelfTest) {
    Write-Host "== 自检 ==" -ForegroundColor Cyan
    # Rest.exe 是 GUI 子系统程序，& 调用不会等它结束，必须取 Process 的退出码
    $p = Start-Process -FilePath $exe -ArgumentList '--self-test' -Wait -PassThru -NoNewWindow
    Write-Host "自检退出码：$($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "自检失败" }
}

if ($Preview) {
    Start-Process $exe -ArgumentList '--preview'
}
