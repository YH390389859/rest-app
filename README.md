# Rest

[![build](https://github.com/YH390389859/rest-app/actions/workflows/build.yml/badge.svg)](https://github.com/YH390389859/rest-app/actions/workflows/build.yml)

休息提醒工具，两个平台各自原生实现：

- **macOS**：Swift + AppKit/SwiftUI，菜单栏应用
- **Windows**：C# / .NET 8 + WPF，托盘应用

参考 [Stretchly](https://github.com/hovancik/stretchly) 的节奏思路，针对三个痛点做了重做：全屏看视频时能在休息遮罩里暂停播放、休息界面接必应每日 4K 壁纸并跨屏覆盖、倒计时结束后按「自动 / 等按钮 / 任意键鼠动作」三种策略收尾。

**节奏模型的语义只有一份**：`macos/Sources/Rest/Scheduler.swift` 与 `windows/src/Rest.Core/BreakPlanner.cs` 逐条对齐，由 Windows 侧 22 个单元测试锁住行为。UI 与媒体控制层按平台各写一套——macOS 靠 CoreAudio + MediaRemote，Windows 靠 SMTC + Core Audio 会话。

## 下载

到 [Releases](https://github.com/YH390389859/rest-app/releases/latest) 取最新版本（`<版本>` 即仓库根 `VERSION` 的内容）：

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| macOS | `Rest-<版本>.dmg` | 拖进「应用程序」即可 |
| macOS | `Rest-<版本>.zip` | 便携包 |
| Windows | `Rest-<版本>-win-x64-setup.exe` | 安装器，按用户安装、不弹 UAC，自带 .NET 运行时 |
| Windows | `Rest-<版本>-win-x64-portable.zip` | 免安装，解压即用 |

要求：macOS 14+；Windows 10 1809+ / 11（x64）。

> 两个包目前都是**未获系统信任的签名**，第一次打开会被系统挡一下：
> macOS 要在「隐私与安全性」里点「仍要打开」，Windows 会弹 SmartScreen（点「更多信息 → 仍要运行」）。
> 开了智能应用控制（SAC）的 Win11 更严格，会直接拦掉，见下面「签名现状」。

## 仓库结构

```
rest-app/
├── VERSION                     # 唯一版本号来源，两个平台构建时都读它
├── LICENSE                     # MIT
├── CODE-SIGNING-POLICY.md      # 签名规则（也是申请免费签名服务要交的材料）
├── macos/                      # Swift Package + 打包脚本
│   ├── Package.swift
│   ├── Sources/Rest/           # 18 个 Swift 文件
│   ├── Resources/              # Info.plist / AppIcon.icns
│   ├── tools/                  # 图标生成 / 自签名证书 / DMG 打包
│   ├── build.sh                # 编译 + 签名 + 可选 --dmg / --install
│   └── README.md               # macOS 侧技术细节
├── windows/                    # .NET 解决方案
│   ├── Rest.sln
│   ├── src/Rest.Core/          # 纯 .NET：节奏模型、设置、存储
│   ├── src/Rest.Platform.Windows/  # SMTC / 音频会话 / 壁纸 / 系统集成
│   ├── src/Rest.App/           # WPF 界面
│   ├── tests/Rest.Core.Tests/  # 22 个节奏模型用例
│   ├── installer/Rest.iss      # Inno Setup 安装器
│   ├── build.ps1               # 编译 + 测试 + 便携包 + 安装器（含两遍签名流程）
│   └── README.md               # Windows 侧技术细节
├── .signpath/                  # 远程签名用的 artifact configuration
└── .github/workflows/build.yml # 一条流水线出两个平台的包
```

两个平台目录完全平行，谁都不寄生在谁里面：根目录没有任何 Swift 或 .NET 工程文件，
`git clone` 之后想构建哪个平台就进哪个目录。

## 构建

macOS（在 `macos/` 下）：

```bash
./build.sh                          # 产出 build/Rest.app
./build.sh release --dmg            # 顺带打 dist/Rest-<版本>.dmg
UNIVERSAL=1 ./build.sh release      # 通用二进制（arm64 + x86_64）
```

Windows（在 `windows/` 下，需要 .NET 8 SDK；打安装器还要 Inno Setup 6）：

```powershell
winget install JRSoftware.InnoSetup
.\build.ps1 -Configuration Release -Test -Zip -Installer
```

版本号不用手改代码：两个脚本默认读仓库根的 `VERSION`，也可以临时用 `VERSION=v1.2.3 ./build.sh` 或 `-Version 1.2.3` 覆盖。

## 发版

1. 改 `VERSION`（比如 `1.1.1`），提交；
2. 打 tag：`git tag -a v1.1.1 -m "..."`；
3. `git push origin main --follow-tags`。

CI（`.github/workflows/build.yml`）的三个 job：

- `version`：读 `VERSION`，**断言 tag 名与它一致**，不一致直接失败；
- `macos` / `windows`：并行构建，各自上传 artifact；
- `release`：只在 tag 上跑，等两个平台都成功，才把 4 个包挂到同一个 Release。

推到 `main` 或开 PR 时也会两边都构建（产物作为 artifact 留 30 天），只是不发 Release——这样任何一次改动都能拿到两个平台的包来验，不用先打 tag。

## 签名现状

| 平台 | 现在 | 用户侧表现 | 彻底解决 |
| --- | --- | --- | --- |
| macOS | 本地自签名证书（CI 用 `SIGNING_P12` secret，没有则 ad-hoc） | 首次打开需在「隐私与安全性」放行；TCC 授权不再随编译失效 | Apple Developer ID + 公证 |
| Windows | 准备接入 SignPath Foundation（开源免费）；也可用 `WINDOWS_SIGN_PFX_BASE64` 走自己的证书 | 未签状态：SmartScreen 提示，SAC 开启时直接拦截（**安装器也一样被拦**） | 受信任 CA 的代码签名证书 |

SAC（智能应用控制）拦的是 PE 镜像加载，和有没有安装器无关：本机（SAC=Enforce）实测运行未签名的
`setup.exe` 会直接报「应用程序控制策略已阻止此文件」。所以「做个安装器」只解决了安装体验，
没解决拦截；那条只能靠受信任证书。

**免费的路子是有的**：SAC 认的是「证书是否来自微软受信任根计划内的 CA」，不看下载量，
所以开源项目可以申请 [SignPath Foundation](https://signpath.org/) 的免费签名（Sectigo 签发），
签一次就过。仓库已经按这个模型把 CI 和打包脚本改好了，审核下来填 3 个变量 + 1 个 secret 即可；
细节和「卸载器同样要签，否则能装不能卸」这条坑见 [windows/README.md](windows/README.md#签名通道)。

签名策略（提供给签名服务的说明）：[CODE-SIGNING-POLICY.md](CODE-SIGNING-POLICY.md)。


## 更多

- macOS 实现细节（媒体控制三级降级、壁纸缓存、遮罩窗口行为）：[macos/README.md](macos/README.md)
- Windows 实现细节（API 映射、调试参数、已知差异、真机验证记录）：[windows/README.md](windows/README.md)
