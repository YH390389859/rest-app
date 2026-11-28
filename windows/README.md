# Rest for Windows

macOS 版（仓库里的 `macos/` 目录）的 Windows 移植，用 **C# / .NET 8 + WPF** 重写平台层。

核心约束：**节奏模型只有一份语义**。`src/Rest.Core/BreakPlanner.cs` 是
`../macos/Sources/Rest/Scheduler.swift` 的逐条移植，并由 `tests/Rest.Core.Tests` 里 22 个用例锁住行为；
改任何一边都必须同步另一边，否则测试会红。

## 为什么不能"直接编译到 Windows"

Swift 那套 UI 和媒体控制层在 Windows 上不存在：

| macOS 依赖 | Windows 上有没有 | 本仓库的处理 |
| --- | --- | --- |
| AppKit / SwiftUI（`NSScreen`、`NSWindow`、`NSStatusItem`） | 没有 | WPF 窗口 + WinForms `NotifyIcon` / `Screen` |
| MediaRemote（**私有框架**，`dlopen`） | 没有 | SMTC `GlobalSystemMediaTransportControlsSessionManager`（**公开 API**） |
| CoreAudio 进程对象 API | 没有 | `IAudioSessionManager2` COM 互操作 |
| AppleScript / 辅助功能点「暂停」按钮 | 没有 | 不需要——SMTC 能按应用直接下发暂停 |
| `SMAppService` 登录启动 | 没有 | `HKCU\...\CurrentVersion\Run` |
| `CGEventSource` 空闲检测 | 没有 | `GetLastInputInfo` |
| `NSSound` 系统音 | 没有 | `winmm.dll!PlaySound` + 系统 wav |

好消息：Windows 的媒体控制反而更简单。macOS 版要实现「系统 Now Playing 槽位 → AppleScript →
辅助功能按按钮」三级降级，是因为系统只有一个 Now Playing 槽；Windows 每个应用有独立 SMTC 会话，
一条 `TryPauseAsync()` 就够了。

## 工程结构

```
windows/
├── Rest.sln
├── build.ps1                      # 对应 macOS 的 build.sh
├── installer/
│   ├── Rest.iss                   # Inno Setup 安装器脚本（按用户安装，不弹 UAC）
│   └── languages/ChineseSimplified.isl   # Inno 官方安装包没带简中，随仓库带一份
├── src/
│   ├── Rest.Core/                 # 纯 .NET，不含任何 Windows API，可在 macOS 上编译+测试
│   │   ├── BreakPlanner.cs        # ← 移植自 Scheduler.swift（唯一需要逐字对齐的类）
│   │   ├── RestSettings.cs        # ← 移植自 AppSettings.swift
│   │   └── Storage.cs             # 设置持久化（JSON）+ IClock 时钟抽象
│   ├── Rest.Platform.Windows/     # WinRT + P/Invoke + COM，无 UI（也能在 macOS 上编译）
│   │   ├── Media/MediaService.cs          # SMTC 枚举 / 暂停 / 恢复
│   │   ├── Media/AudioSessionInterop.cs   # Core Audio 会话枚举，补上没 SMTC 的播放器
│   │   ├── Wallpaper/BingWallpaperService.cs
│   │   └── Host/SystemServices.cs         # 空闲检测 / 开机自启 / 提示音
│   ├── Rest.App/                  # WPF 界面（WPF 工程只能在 Windows 上跑，但能在 macOS 上编）
│   │   ├── App.xaml.cs            # 对应 AppDelegate.swift
│   │   ├── BreakCoordinator.cs    # 对应 BreakCoordinator.swift
│   │   ├── TrayIconHost.cs        # 对应 StatusBarController.swift
│   │   └── Views/                 # BreakView / SettingsView / OverlayManager
│   └── Resources/Rest.ico         # 由 AppIcon.icns 转出来的 16/32/128/256 图标
└── tests/Rest.Core.Tests/         # 节奏模型契约测试
```

## 构建

要求：Windows 10 1809+ / Windows 11，.NET 8 SDK。打安装器还需要 Inno Setup 6。

```powershell
winget install JRSoftware.InnoSetup        # 只在要 -Installer 时需要
```

> 装 SDK 时注意：若系统开着 WinINET 代理（`127.0.0.1:7890` 之类），`dotnet-install.ps1`
> 会走代理并可能长时间卡在下载阶段。用 `curl.exe -L --noproxy '*'` 直接下 zip 再
> `Expand-Archive` 最稳妥。

```powershell
cd windows
.\build.ps1                                    # Debug 构建到 dist/win-x64
.\build.ps1 -Configuration Release -Test -Zip  # 跑测试 + 出 Release 便携包
.\build.ps1 -Configuration Release -Zip -Installer   # 再额外打一个安装器
.\build.ps1 -SelfTest                          # 构建后跑一次无界面自检
```

产物（版本号取自仓库根的 `VERSION`，也可以用 `-Version` 覆盖）：

| 文件 | 说明 |
| --- | --- |
| `dist/win-x64/` | self-contained 发布目录（自带 .NET 运行时，约 70 MB） |
| `dist/Rest-<版本>-win-x64-portable.zip` | 免安装包，解压即用 |
| `dist/Rest-<版本>-win-x64-setup.exe` | 安装器，约 51 MB（LZMA2 压缩后） |

也可以直接用 SDK 命令：

```powershell
dotnet test tests/Rest.Core.Tests/Rest.Core.Tests.csproj
dotnet publish src/Rest.App/Rest.App.csproj -c Release -r win-x64 --self-contained -o dist/win-x64
```

**交叉编译**：`Rest.Core` 和 `Rest.Platform.Windows` 在 macOS / Linux 上也能 `dotnet build`
（前者纯 .NET，后者只用到 WinRT 投影和 P/Invoke 声明）。`Rest.App` 需要
`-p:EnableWindowsTargeting=true` 才能在 macOS 上编译，产物可以正常在 Windows 上运行。

## 安装器

`installer/Rest.iss`（Inno Setup 6）生成 `Rest-<版本>-win-x64-setup.exe`，几个刻意的选择：

- **按用户安装**：`PrivilegesRequired=lowest`，装到 `%LOCALAPPDATA%\Programs\Rest`，不弹 UAC，
  不需要管理员权限。休息提醒是常驻托盘的个人工具，没必要进 `Program Files`。
- **固定目录 + 固定 AppId**：升级时原地覆盖，「应用和功能」里只有一条卸载项，
  不会像便携版那样换个解压目录就多出一份互不相认的副本。
- **不替用户开机自启**：那件事归应用自己的设置项管。
- **卸载保留设置**：只删安装目录，`%LOCALAPPDATA%\Rest` 下的设置和壁纸缓存留着，
  重装回来还是原来的节奏。
- 安装器界面是简体中文（`installer/languages/ChineseSimplified.isl`）。

CI 里会对安装器做一次冒烟测试：静默装到临时目录 → 断言 `Rest.exe` / `Rest.Core.dll` / `unins000.exe`
都在 → 跑一次 `--self-test` → 静默卸载 → 断言目录已清空。只「编译通过」不算数。

> ⚠️ 安装器解决的是「装起来体不体面」，**不解决 SAC 拦截**：`setup.exe` 自己也是未签名 PE，
> 在开着 SAC 的机器上同样被拦（本机实测报「应用程序控制策略已阻止此文件」）。要真正消除拦截，
> 只有受信任代码签名证书一条路，见下一节。

## 在 Windows 上运行的前提：Smart App Control

Win11 的智能应用控制（SAC）会拦截**所有未取得微软云端信誉的可执行文件**，包括我们自己编译的
`Rest.exe`。表现是双击毫无反应、没有任何报错，事件日志里只有一行：

```
'Rest.exe' was blocked by your organization's Device Guard policy.
```

它拦在**镜像加载**这一层（CodeIntegrity 事件 3077/3118），所以：

- **自签名证书签名无效**。实测把自签证书装进「受信任的根 + 受信任的发布者」再签 `Rest.exe`，
  `Get-AuthenticodeSignature` 显示 `Valid`，但 SAC 照样拒绝执行——它认微软云端信誉，不认本地信任链。
- `--self-test` / `--render` 也一起被拦，headless 模式救不了这个问题。

三种处理方式：

| 方式 | 代价 |
| --- | --- |
| 关掉 SAC（Windows 安全中心 → 应用和浏览器控制 → 智能应用控制） | **关掉后只能通过重装/重置系统才能再开启**，微软明确如此 |
| 用受信任的代码签名证书签（Azure Trusted Signing 等） | 需实名与订阅，但这是对外分发唯一正规的解法 |
| 在未开启 SAC 的机器或虚拟机上测试 | 只够开发自测，解决不了用户侧问题 |

> 对外发布前必须处理这条：新装 Win11 有相当比例的机器开着 SAC，
> 用户下载 zip 解压双击会**完全没反应**，连个错误框都不弹。

**安装器也躲不过**：本机（SAC=Enforce）实测运行 `Rest-1.1.0-win-x64-setup.exe`，PowerShell 直接报
「应用程序控制策略已阻止此文件」，连安装向导都出不来。拦的是 PE 加载，安装器同样是未签名 PE。

真正解掉这条只有受信任签名。CI 和 `build.ps1` 已经接好签名通道，拿到证书后配两个 secret 即可：

| secret / 环境变量 | 内容 |
| --- | --- |
| `WINDOWS_SIGN_PFX_BASE64` | 代码签名证书（.pfx）的 base64；为空就跳过签名 |
| `WINDOWS_SIGN_PFX_PASS` | pfx 密码 |

配了就会用 `signtool` 以 SHA256 + DigiCert 时间戳签 `Rest.exe` 和 `setup.exe`，签失败直接让构建红掉，
不会悄悄发一个没签的包。个人开源项目可看 Certum 的 Open Source Code Signing（比 OV/EV 便宜得多，
但要有公开仓库）；Azure Trusted Signing 需要组织资质，个人不好过。

### 开发自测的临时绕过：用 dotnet 宿主加载

SAC 拦的是**镜像加载**这一步——被地图加载的是 `Rest.exe` 这个 apphost；托管程序集走 CLR
自己的加载器，不过这道检查。所以「框架依赖 + `dotnet Rest.dll`」在开着 SAC 的机器上能正常跑：

```powershell
dotnet publish src/Rest.App/Rest.App.csproj -c Release `
  -f net8.0-windows10.0.19041.0 --no-self-contained -o dist/fx
dotnet dist/fx/Rest.dll              # 正常启动（托盘 + 计时）
dotnet dist/fx/Rest.dll --self-test  # 自检
dotnet dist/fx/Rest.dll --render C:\temp\break.png
```

真机实测（Win11 26300、SAC=Enforce）：`Rest.exe` 直接双击/命令行都是 `Permission denied`，
事件日志 3077/3118 记一次拦截；同目录换成 `dotnet Rest.dll` 五项自检全过、托盘和遮罩都正常。

**这只够自己调试**：用户机器上没有 .NET 运行时，也不会敲命令，对外分发仍然必须走签名。

## 调试参数（对齐 macOS 版的同名参数）

| 参数 | 作用 |
| --- | --- |
| `--preview` | 启动 0.8 秒后弹一次休息界面 |
| `--render <路径>` | 把休息界面离屏渲染成 PNG（2560×1440），**不需要桌面会话** |
| `--render-settings <路径>` | 渲染设置界面 PNG |
| `--dump-media` | 打印当前所有音频源及其可控性 |
| `--test-pause [关键字]` | 对匹配的音频源执行一次暂停→恢复，验证通道 |
| `--self-test` | 无界面自检：设置读写 / 节奏模型 / 音频枚举 / 壁纸 / 显示器，失败返回 1 |
| `--verbose` | 打印节奏与倒计时日志 |

`--self-test` 和 `--render` 是为远程调试准备的：看不到桌面也能判断"跑没跑起来、界面长什么样"，
日志同时写到 `%TEMP%\rest-debug.log`。

但**通过 SSH 登录跑不起 GUI 进程**：Windows OpenSSH 的会话落在 Session 0（服务会话），
没有交互桌面——实测连 `notepad` 都起不来，WPF 窗口自然也没有。要在无人值守的情况下验证界面，
需要用计划任务把进程投到已登录用户的会话（`/it` 表示"仅用户登录时运行"，**未实测**）：

```powershell
schtasks /create /tn RestSelfTest /tr "C:\...\Rest.exe --self-test" /sc once /st 23:59 /ru <用户名> /it /f
schtasks /run /tn RestSelfTest
```

## 行为对齐清单

已经按 macOS 版逐条实现的：

- [x] 节奏模型：每段工作 = 小憩间隔；`breakNumber % slots == 0` 时来长休息
- [x] 跳过不占槽位；推迟会把槽位还回去，N 分钟后再来同一种
- [x] 长休息结束后计数归零
- [x] 只开一种休息时退化成纯时间间隔（只开休息 → 一段工作 = 一个完整周期）
- [x] 严格模式按类型分别生效，禁用对应的跳过 / 延后按钮和菜单项
- [x] 两种「结束行为」：直接进入下一轮 / 停留等按钮 / 透明遮罩 + 任意操作（800ms 宽限期）
- [x] 多屏遮罩（可只遮主屏）；分辨率变化 / 插拔屏幕时整块重铺，200ms 防抖
- [x] 人不在电脑前（>120s 无输入）跳过本次休息，预览模式不受此限
- [x] 必应每日壁纸：8 天窗口轮换、按 id 缓存、预取下一张、超过 24 张清理
- [x] 音频源列表：每 5 秒刷新，中途开新视频也能列出来；单行暂停 / 恢复、全部暂停
- [x] 休息结束按设置恢复播放；用户自己播起来了就不插手
- [x] 托盘菜单状态文案（下次小憩/休息、N 次小憩后、严格模式提示）
- [x] 提示音、开机自启

## 已知差异（有意为之）

1. **字体与字距**：macOS 用 `.system(size:weight:design:.rounded)` 且对标题做了 `tracking(8)`；
   WPF 没有字距属性，标题用 14pt 粗体近似（差一点点疏朗感）。
2. **遮罩不用分层透明窗口**：`AllowsTransparency=false` 走普通窗口，4K 壁纸性能好得多；
   代价是「透明遮罩」模式改为「隐藏窗口 + 低层钩子」，视觉结果一致。
3. **图标来源**：macOS 用 `NSWorkspace` 拿应用图标；Windows 用
   `Icon.ExtractAssociatedIcon(进程主模块)`，权限受限的进程拿不到图标，界面退回首字母。
4. **设置界面**：原生 WPF 控件（自绘开关 / 步进器），不是 SwiftUI Form 的观感，
   分组和文案保持一致。
5. **权限**：Windows 版**不需要任何授权**（没有辅助功能 / 自动化概念）。

## 真机验证记录

环境：Windows 11 26300 / x64，双 4K 屏（主屏 3840×2160 @150%，副屏 3840×2160 @200%，副屏在主屏左侧）。

已验证：

- [x] 启动、托盘、单实例互斥（第二个实例打印「Rest 已在运行」后退出，退出码 0）
- [x] 双屏混合 DPI：两块遮罩窗口的物理矩形分别是 `(0,0,3840×2160)` 与 `(-3840,0,3840×2160)`，
      各自铺满、内容水平居中（实测偏差 ≤1px），200% 屏上的界面比 150% 屏大约 1.33 倍，符合 DPI 缩放
- [x] 必应每日壁纸：显示、右下角版权文案、8 天轮换的图片缓存都正常
- [x] `--self-test` 五项全过；`Rest.Core.Tests` 22 个用例全绿
- [x] `--render` / `--render-settings` 离屏渲染正常，可用于没有桌面的远程排查
- [x] **修掉一个首次打开设置窗口必崩的 bug**：`SettingsView.xaml` 里 `Run.Text` 绑定
      `LongCycleMinutes` 时没写 `Mode=OneWay`，而 `Run.Text` 默认 TwoWay、该属性是只读计算属性，
      WPF 在首次布局时抛 `InvalidOperationException`（真机上表现为设置窗口闪一下就没了）

还没验证：

- 全屏应用、独占全屏游戏之上能否覆盖
- SMTC 对各家播放器的实际可控性（Chrome / Edge / Spotify / QQ 音乐 / 网易云 / PotPlayer）
- 托盘图标在 Win11 的溢出区表现
- 壁纸在 4K 屏上的加载耗时（4K 图在双屏上都加载正常，耗时可接受）
