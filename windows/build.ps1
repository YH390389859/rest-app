<#
.SYNOPSIS
    Rest 的 Windows 构建脚本（对应 macOS 的 build.sh）。

.DESCRIPTION
    需要在装了 .NET 8 SDK 的 Windows 上运行。参数：
      -Configuration Release   默认 Debug
      -Test                    先跑核心逻辑单元测试
      -Zip                     把产物打成 windows/dist/Rest-<版本>-win-x64.zip
      -SelfTest                构建后跑一次无界面自检（会打印到当前控制台）
      -Preview                 构建后直接启动并弹一次休息界面

.EXAMPLE
    .\build.ps1 -Configuration Release -Test -Zip
#>
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$Test,
    [switch]$Zip,
    [switch]$SelfTest,
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$appProject = Join-Path $root 'src/Rest.App/Rest.App.csproj'
$testProject = Join-Path $root 'tests/Rest.Core.Tests/Rest.Core.Tests.csproj'
$outDir = Join-Path $root "dist/win-x64"

Write-Host "== 环境 ==" -ForegroundColor Cyan
dotnet --version

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
    -o $outDir

if ($LASTEXITCODE -ne 0) { throw "发布失败" }

$exe = Join-Path $outDir 'Rest.exe'
if (-not (Test-Path $exe)) { throw "产物里没有 Rest.exe" }

Write-Host "产物：$exe" -ForegroundColor Green

if ($Zip) {
    $version = (Get-Item $exe).VersionInfo.ProductVersion
    if (-not $version) { $version = 'dev' }
    $zipPath = Join-Path $root "dist/Rest-$version-win-x64.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath
    Write-Host "压缩包：$zipPath" -ForegroundColor Green
}

if ($SelfTest) {
    Write-Host "== 自检 ==" -ForegroundColor Cyan
    & $exe --self-test
    Write-Host "自检退出码：$LASTEXITCODE"
}

if ($Preview) {
    Start-Process $exe -ArgumentList '--preview'
}
