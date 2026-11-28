<#
.SYNOPSIS
    Rest 的 Windows 构建脚本（对应 macOS 的 macos/build.sh）。

.DESCRIPTION
    需要在装了 .NET 8 SDK 的 Windows 上运行。参数：
      -Configuration Release   默认 Debug
      -Test                    先跑核心逻辑单元测试
      -Zip                     打出 dist/Rest-<版本>-win-x64-portable.zip（免安装）
      -Installer               打出 dist/Rest-<版本>-win-x64-setup.exe（需要 Inno Setup 6）
      -SignUninstaller         让安装器内嵌已签名的卸载器（要求 dist\unins 下待签样本已签好）
      -SignStub                只产出待签名卸载器样本 dist\unins\uninst-*.e32 然后退出
      -SelfTest                构建后跑一次无界面自检（会打印到当前控制台）
      -Preview                 构建后直接启动并弹一次休息界面
      -Version 1.2.3           覆盖版本号；默认读仓库根的 VERSION 文件
      -NoPublish               跳过 dotnet publish，复用现有 dist/win-x64
      -NoSign                  跳过本地 signtool 签名（签名交给 CI 的远程服务时用）

.EXAMPLE
    .\build.ps1 -Configuration Release -Test -Zip -Installer

.EXAMPLE
    # CI 里的"远程签名"两遍流程（本地没有证书）
    .\build.ps1 -Configuration Release -NoSign -Test      # 发布，不签名
    .\build.ps1 -NoPublish -SignStub                      # 第一遍：产出待签卸载器后中止
    #   → 把 Rest.exe 与 uninst-*.e32 交给签名服务，回填
    .\build.ps1 -NoPublish -NoSign -Installer -SignUninstaller
    .\build.ps1 -NoPublish -NoSign -Zip

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
    [switch]$SignUninstaller,
    [switch]$SignStub,
    [switch]$SelfTest,
    [switch]$Preview,
    [switch]$NoPublish,
    [switch]$NoSign,
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

$exe = Join-Path $outDir 'Rest.exe'

$distDir = Join-Path $root 'dist'
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }
$uninsDir = Join-Path $distDir 'unins'

if ($NoPublish) {
    Write-Host "== 跳过发布，复用 $outDir ==" -ForegroundColor Cyan
    if (-not (Test-Path $exe)) { throw "-NoPublish 但 $exe 不存在，先跑一次不带 -NoPublish 的构建" }
}
else {
    Write-Host "== 发布 $Configuration / win-x64 ==" -ForegroundColor Cyan
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    # 上一次留下的卸载器样本必须清掉：它绑着旧的图标与版本资源，
    # 混进新安装器就成了「旧签名 + 新内容」，签名会校验不过
    if (Test-Path $uninsDir) { Remove-Item $uninsDir -Recurse -Force }

    dotnet publish $appProject `
        -c $Configuration `
        -r win-x64 `
        --self-contained true `
        -p:PublishReadyToRun=false `
        -p:Version=$Version `
        -o $outDir

    if ($LASTEXITCODE -ne 0) { throw "发布失败" }

    if (-not (Test-Path $exe)) { throw "产物里没有 Rest.exe" }
}

Write-Host "产物：$exe" -ForegroundColor Green

# 有证书就签，没有就跳过。SmartScreen / 智能应用控制只认受信任的签名，
# 自签名和「不签」在陌生机器上是同一个结果，所以这里不做自签名兜底。
# -NoSign 用于签名交给远程服务（SignPath）的场景：本地不留私钥，签不了。
function Sign-Artifact([string]$Path) {
    if ($NoSign) { return }
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

function Get-Iscc {
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
        )
        $iscc = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if (-not $iscc) { throw "找不到 ISCC.exe（Inno Setup）。装一个：winget install JRSoftware.InnoSetup" }
    return $iscc
}

# 输出目录显式钉在 windows/dist，不依赖 .iss 里的 OutputDir
function Invoke-Iscc([switch]$WithSignedUninstaller) {
    $iscc = Get-Iscc
    $isccArgs = @("/DAppVersion=$Version", "/O$distDir")
    if ($WithSignedUninstaller) { $isccArgs += '/DSignUninstaller' }
    $isccArgs += (Join-Path $root 'installer/Rest.iss')

    # ISCC 把「待签名卸载器」这类提示写到 stderr，而 PS 5.1 在
    # ErrorActionPreference=Stop 下会把原生命令的 stderr 当成终止错误抛出来，
    # 于是 -SignStub 那一遍还没走到检查样本就退出了。这里临时放宽，退出码自己判断。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $iscc @isccArgs 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
}

function Get-UninstallerStub {
    if (-not (Test-Path $uninsDir)) { return $null }
    Get-ChildItem $uninsDir -Filter 'uninst-*.e32' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Test-Signed([string]$Path) {
    # 自签名会返回 UnknownError（根证书不受信），但确实带签名，所以只排除 NotSigned
    (Get-AuthenticodeSignature $Path).Status -ne 'NotSigned'
}

if ($SignStub) {
    Write-Host "== 第一遍：产出待签名卸载器 ==" -ForegroundColor Cyan
    # 打开 SignedUninstaller 后，ISCC 生成样本就会主动中止（退出码非 0），这是设计如此：
    # 它要求你把样本拿去签，签完再编译一遍。所以这一遍不看退出码。
    $null = Invoke-Iscc -WithSignedUninstaller
    $stub = Get-UninstallerStub
    if (-not $stub) { throw "ISCC 没有产出 uninst-*.e32，检查 Rest.iss 的 SignedUninstallerDir" }
    if (Test-Signed $stub.FullName) { Write-Host "样本已有签名，无需再签" -ForegroundColor Yellow }
    Write-Host "待签名卸载器：$($stub.FullName)" -ForegroundColor Green
    # 这一遍 ISCC 的退出码是 2（中止），但对我们来说是正常的：显式归零，
    # 免得 CI 把「预期内的中止」当成失败
    exit 0
}

if ($Installer) {
    Write-Host "== 生成安装器 ==" -ForegroundColor Cyan
    $code = Invoke-Iscc -WithSignedUninstaller:$SignUninstaller
    if ($code -ne 0) {
        $stub = Get-UninstallerStub
        if ($SignUninstaller -and $stub -and -not (Test-Signed $stub.FullName)) {
            throw "卸载器样本还没签名：$($stub.FullName)。签完放回原处再编译（或先跑 -SignStub 产出样本）"
        }
        throw "安装器编译失败（ISCC exit=$code）"
    }

    $setup = Join-Path $distDir "Rest-$Version-win-x64-setup.exe"
    if (-not (Test-Path $setup)) { throw "没生成 $setup" }
    Sign-Artifact $setup
    Write-Host "安装器：$setup（$([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB）" -ForegroundColor Green
}

# 便携包放在安装器之后打：远程签名流程里 Rest.exe 是中途被替换成已签名版本的，
# zip 必须在最后一刻收，否则打进去的还是未签名的那份
if ($Zip) {
    $zipPath = Join-Path $distDir "Rest-$Version-win-x64-portable.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # 用系统自带的 bsdtar（Win10 1809+ 的 System32\tar.exe），不用 Compress-Archive：
    # 后者在 PS 5.1 里每写一个文件就刷一行进度条，$ProgressPreference 压不住，
    # CI 日志会多出几万行；压这个 70 MB 目录也要慢好几倍（实测 5s vs 20s+）。
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Push-Location $outDir
            & $tar -a -c -f $zipPath *
            $code = $LASTEXITCODE
        }
        finally {
            Pop-Location
            $ErrorActionPreference = $prev
        }
        if ($code -ne 0) { throw "打包失败（tar exit=$code）" }
    }
    else {
        Write-Host "没有 System32\tar.exe，退回 Compress-Archive" -ForegroundColor Yellow
        Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath
    }
    Write-Host "便携包：$zipPath（$([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB）" -ForegroundColor Green
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
