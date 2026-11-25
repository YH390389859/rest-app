# Rest

[![build](https://github.com/YH390389859/rest-app/actions/workflows/build.yml/badge.svg)](https://github.com/YH390389859/rest-app/actions/workflows/build.yml)

一个参考 [Stretchly](https://github.com/hovancik/stretchly) 思路、用原生 Swift + AppKit/SwiftUI 写的 macOS 休息提醒菜单栏应用。

针对三个具体痛点做了重做：

1. **看视频时进入休息，全屏下没法暂停视频** → 自动识别"谁在占用音频 / 谁在播放"，一键（或自动）暂停。
2. **界面太朴素** → 接入必应每日壁纸（4K），跨全屏覆盖。
3. **倒计时结束直接跳到下一轮，和界面显示不符** → 支持"停留等按钮"或"全透明遮罩 + 任意键鼠动作才继续"。

## 构建与运行

```bash
./build.sh                          # 产出 build/Rest.app（arm64）
./build.sh release --dmg            # 顺带打 dist/Rest-1.0.0.dmg
./build.sh release --install        # 顺带装到 /Applications 并启动
UNIVERSAL=1 ./build.sh release      # 通用二进制（arm64 + x86_64），慢一倍
VERSION=v1.2.0 ./build.sh release   # 指定版本号，写进 Info.plist
open build/Rest.app                 # 直接运行（或拖到 /Applications）
```

DMG 里就是 `Rest.app` + 一个指向 `/Applications` 的快捷方式，双击挂载后拖过去即可。嫌不够好看可以自己加背景图和图标位置，但那样得靠 Finder 摆（CI 里没有 Finder 会话，AppleScript 会失败），所以这里保持纯 `hdiutil`、无脚本依赖。

要求 macOS 14+、Xcode 命令行工具。打包是 ad-hoc 签名；"登录时自动启动"需要把 App 放到 `/Applications` 才能真正生效。

### 自动打包

`.github/workflows/build.yml`：push 到 `main`、开 PR、手动触发都会跑，产出 arm64 + x86_64 的通用二进制，同时打 `.zip` 和 `.dmg`，作为 artifact 保留 30 天；推一个 `v*` tag（如 `git tag v1.0.1 && git push --tags`）会把版本号写进 Info.plist，并把两个包直接发到 GitHub Releases。


调试用参数：

```bash
./build/Rest.app/Contents/MacOS/Rest --preview                    # 启动后立即弹一次休息界面
./build/Rest.app/Contents/MacOS/Rest --render /tmp/ui.png         # 把休息界面离屏渲染成 PNG（不需要录屏权限）
./build/Rest.app/Contents/MacOS/Rest --render-settings /tmp/s.png # 渲染设置界面（走窗口 cacheDisplay）
./build/Rest.app/Contents/MacOS/Rest --verbose                    # 打印节奏与倒计时日志
```

## 节奏模型（对齐 Stretchly）

默认值直接照 Stretchly 来：

| | 持续时间 | 间隔 |
|---|---|---|
| 小憩 | 20 秒 | 每 10 分钟 |
| 休息 | 5 分钟 | 2 次小憩后（约 30 分钟） |

这里有个容易搞错的地方：**长休息不是独立计时的，而是挂在「槽位」上**。Stretchly 的 `app/breaksPlanner.js` 里，每一段工作的长度都等于小憩间隔，然后靠 `breakNumber % (longBreakInterval + 1) === 0` 决定这次该小憩还是休息——托盘提示才会写成「下次休息 2 次小憩后」而不是「大约 20 分钟后」。所以设置里的「休息 每 30 分」其实是 10 分 × 3 个槽位的换算结果，改小憩间隔会连带改变休息的实际发生时间。

几条随之而来的规则：

- 每完成一次休息，计数归零重新数（10 → 20 → 30 分各一次，30 分那次是长休息）。
- 跳过休息不占槽位；延后休息会把这一种休息的槽位还回去，N 分钟后再来同一种。
- 只开小憩或只开休息时退化成纯时间间隔：只开休息的话，一段工作就直接等于一个完整周期。
- 「严格模式」按类型分别生效，打开后对应类型的跳过 / 延后按钮和菜单项都会被禁用。

## 图标

`Resources/AppIcon.icns` 由 `tools/make-icon.swift` 生成：CoreGraphics 画渐变圆角方块（Apple 的 1024/824/185 网格）+ 白色茶杯 + 两道热气，10 个尺寸交给 `iconutil` 打包成 icns。改配色或造型后重新生成：

```bash
swiftc -O tools/make-icon.swift -o /tmp/makeicon && /tmp/makeicon Resources/AppIcon.icns
```

`build.sh` 在 icns 缺失时会自动调用它，所以克隆下来直接 `./build.sh` 也有图标。

## 三个问题的技术实现

### 1. 检测"正在占用音频的应用"并暂停

**枚举音频占用者** —— CoreAudio 的「进程对象」API（macOS 14.2+ 公开 API，**不需要任何权限**）：

| 用途 | API |
| --- | --- |
| 拿到系统里所有参与音频的进程 | `kAudioHardwarePropertyProcessObjectList` |
| 该进程是否有活跃输出流 | `kAudioProcessPropertyIsRunningOutput` |
| 进程 PID / bundle id | `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID` |
| 给定 PID 反查进程对象 | `kAudioHardwarePropertyTranslatePIDToProcessObject` |

Chromium / WebKit 的音频跑在 helper 进程里，代码里会把 `com.google.Chrome.helper` 归并回 `com.google.Chrome`，否则界面会显示成一堆"Google Chrome Helper"。

**注意**：`IsRunningOutput == 1` 只代表"音频输出流开着"，播放器暂停后常常仍然保持这条流。所以它只能当"候选"，不能当"正在播放"。

**判断是否真的在播** —— `MediaRemote.framework`（系统私有框架）：

- `MRMediaRemoteGetNowPlayingApplicationPID` → 当前媒体属于哪个 App
- `MRMediaRemoteGetNowPlayingApplicationIsPlaying` → 是否真的在播放
- `MRMediaRemoteGetNowPlayingInfo` → 标题 / 播放速率

**下发暂停** —— 同一框架的 `MRMediaRemoteSendCommand`：

| 命令 | 值 |
| --- | --- |
| play | 0 |
| pause | 1 |
| togglePlayPause | 2 |
| stop | 3 |

它和键盘上的媒体键效果等价，但**不需要辅助功能授权**，也不会像 AppleScript 那样弹出「自动化」权限申请。

**多个播放器同时出声时的问题** —— 系统只有一个 Now Playing 槽位，`MRMediaRemoteSendCommand` 只会作用在其中一个上，Chrome 在放视频、网易云在放歌时，另一个照旧响。

有个看起来更合适的私有 API `MRMediaRemoteSendCommandToApp`（可以按 bundle id 定向下发），但实测/查证结论是**用不了**：

- 它的真实签名是 7 个参数（`command, options, MROriginProtobuf, bundleID, sendOptions, queue, block`）；
- 更重要的是，第三方签名的进程调用后，指令会被系统**重定向到当前 Now Playing 播放器**；真正定向路由需要 Apple 私有的 `com.apple.mediaremote.send-commands` entitlement，外部签名一加就会在启动时崩溃。

所以这里改成**逐个应用挑选可用通道**，由 `PerAppMediaControl` 实现：

| 通道 | 用在谁身上 | 代价 |
| --- | --- | --- |
| 系统媒体控制（MediaRemote） | 当前 Now Playing 那个应用 | 无 |
| AppleScript | 脚本字典（`Contents/Resources/*.sdef`）里真的声明了 `pause` / `playpause` 的应用，如 Music、Spotify、VLC、IINA | 首次弹一次「自动化」授权 |
| 辅助功能（AX） | 其余应用：遍历它的 AX 树，找文案是「暂停 / Pause」的按钮按下去 | 需要「辅助功能」授权 |

判断能否用 AppleScript 是**读 sdef 静态判断**，不靠"发一条试试"——后者会在休息弹出时触发授权弹窗。AX 遍历带节点数（2200）和深度（7）上限，避免 Chrome 这种大树把主线程卡住；只有文案完全匹配「暂停 / pause / 播放暂停」的按钮才会按，避免误点「暂停下载」。

都没有通道的（比如 `afplay` 这种没有界面也没有 bundle 的命令行进程）会如实显示「无法自动暂停」，而不是给一个按了没反应的按钮。

界面上不再是一个「暂停「XXX」」按钮，而是一张音频卡片：每个应用一行（图标 + 名称 + 歌名/歌手 + 单独暂停/恢复），顶部有「全部暂停」。行数超过 4 个时自动压缩行高，超过 6 个时底部提示用「全部暂停」一起处理。休息期间每 5 秒刷新一次，中途开新视频也会列出来。

休息结束时只恢复**被我们暂停过、且现在还停在暂停状态**的那些：Now Playing 那个要求 PID 没变、`isPlaying` 仍为 false；AppleScript / AX 通道的要求该应用当前没有音频输出（说明用户没自己播起来）。

降级链路：`MediaRemote pause` → 校验 `isPlaying == false` → 失败则模拟 `NX_KEYTYPE_PLAY` 媒体键（这条路需要辅助功能授权，所以只做兜底）。

自动暂停是**默认开启**的（`autoPauseMedia` 默认 `true`，休息结束自动恢复默认也开）。注意它读的是本地已保存的偏好：老版本装过、之后手动关掉的话，升级后仍然是关着的，去设置里确认一眼。休息中途新开的视频只会出现在列表里，不会自动按下去——避免和用户刚点的播放打架。

### 辅助功能授权为什么"点了没反应"

系统那个「是否允许 Rest 控制这台电脑」的弹窗，对同一个应用**只会弹一次**。之前点过拒绝、或者签名变过被系统当成新应用，再调 `AXIsProcessTrustedWithOptions(prompt: true)` 就是彻底静默，什么都不会发生。

所以「去授权」现在做三件事：先尝试弹系统窗，然后**无条件打开系统设置**的辅助功能页，再每秒轮询一次授权状态——你在列表里勾上 Rest，这边会自动变成「已授权」；旁边还留了个「重新检测」手动兜底。

本地打包是 ad-hoc 签名，`codesign` 的哈希每次编译都会变，TCC 会认为换了应用、旧授权作废。想少折腾就 `./build.sh release --install` 装到 `/Applications/Rest.app`（脚本会校验 bundle id 再覆盖），位置固定后只需要在列表里重新勾一次。

### 2. 必应每日壁纸

```
https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN
```

返回 JSON 里的 `images[0].url`（`/th?id=OHR.xxx_UHD.jpg`），拼上 `uhd=1&uhdwidth=3840&uhdheight=2160` 拿 4K 原图，`images[0].copyright` 作为署名显示在右下角。

**每次休息换一张新图**，而不是一天只换一次：用 `idx=0..7&n=8` 一次取回最近 8 天的图，用一份持久化的"上次用过的序号"轮换，保证相邻两次不重复。图片按图片 id 缓存在 `~/Library/Application Support/Rest/wallpapers/`，命中缓存直接读盘；断网时回退到已缓存的最近一张。休息开始前会**预取下一张**（`prepareNext`），所以点「立即休息」时是瞬间换图、没有等待空窗。

### 3. 休息结束的三种策略

配置项 `breakEndBehavior`：

- `auto` —— 和 Stretchly 一样，倒计时归零直接进下一轮。
- `manual` —— 停在结束界面，必须点「开始下一轮」。
- `waitForInput` —— 倒计时归零后，遮罩内容淡出成全透明（窗口还在、还吃输入），用户看起来就像"已经可以操作了"；捕获到第一次键盘/鼠标/触控板动作后，关闭遮罩并开始下一轮。

关键点是这个遮罩窗口：

```swift
window.level = .screenSaver                                  // 1000，压在全屏应用之上
window.collectionBehavior = [.canJoinAllSpaces,              // 任何 Space 都出现
                             .fullScreenAuxiliary,           // 能盖住别人的全屏
                             .stationary, .ignoresCycle]
window.backgroundColor = .clear
window.isOpaque = false
```

`OverlayWindow` 重写了 `canBecomeKey`，所以窗口激活后能直接收到键盘事件；透明状态下 `alphaValue` 保持 1（置 0 有被 WindowServer 跳过命中测试的风险），只是 SwiftUI 内容画成 `Color.clear`。输入捕获用 `NSEvent.addLocalMonitorForEvents`（键盘/鼠标/滚轮/触控板手势），另加一层全局鼠标监听兜底——鼠标类全局事件不需要授权，键盘类需要，所以只兜鼠标。

## 代码结构

```
Sources/Rest/
  main.swift                  入口，设置 accessory 激活策略（纯菜单栏）
  AppDelegate.swift           组装与首启逻辑
  AppSettings.swift           全部设置项（UserDefaults）+ 空闲检测 + 音效
  Scheduler.swift             工作/休息状态机（槽位计数决定小憩还是休息）
  AudioActivityMonitor.swift  CoreAudio 进程对象枚举
  MediaSource.swift           音频源模型 + 控制通道类型
  PerAppMediaControl.swift    AppleScript / 辅助功能 / 媒体键三种单应用控制
  MediaRemoteBridge.swift     MediaRemote 私有框架的 dlsym 封装
  MediaController.swift       多音源快照 / 逐个暂停 / 恢复
  WallpaperService.swift      必应壁纸下载与缓存
  BreakViewModel.swift        休息界面状态
  BreakView.swift             SwiftUI 休息界面
  BreakWindowController.swift 跨屏遮罩窗口 + 输入捕获
  BreakCoordinator.swift      把上面这些串起来
  StatusBarController.swift   菜单栏图标与菜单
  SettingsView.swift          设置窗口
  DebugRender.swift           离屏渲染调试

tools/
  make-icon.swift             生成 AppIcon.icns
```

计时用「目标时间戳」而不是自增计数器，睡眠唤醒后不会漂移。空闲超过 2 分钟会跳过这次休息（可在设置里关掉）。

界面上的倒计时不是自己算的：`Scheduler` 每 0.25s 通过 `onBreakTick(remaining, total)` 把剩余时间推给 `BreakCoordinator`，后者写进 `BreakViewModel.remaining`。这样状态机和界面只有一个数据源，不会出现"环在转、数字不动"或反过来。

## 已知边界

- `MediaRemote.framework` 是私有 API，随系统版本有变化风险；失效时会自动退化为媒体键模拟。
- `IsRunningOutput == 1` 只代表"输出流开着"。播放器暂停后常常仍保持这条流（Music、Chrome 都是），所以列表里可能出现在"其实没在播"的应用。这是公开 API 能给到的最准的信息，界面上按「占用音频输出」呈现，点暂停对它也是安全的空操作。
- 辅助功能授权绑定代码签名：从 `build/` 直接跑、每次重新编译签名都会变，需要重新授权一次。想稳定就把 `Rest.app` 拖进「应用程序」。
- 第三方应用能否被 AX 控制取决于它自己：原生播放器一般能找到「暂停」按钮，浏览器里的网页播放器要 Chrome 把无障碍树暴露出来才可能命中，命中不了会如实显示「无法自动暂停」。
- 遮罩捕获到输入时，那一下点击/按键会被吞掉（本来就是"我回来了"的确认动作）。
- 主要针对单用户本机使用，未做沙盒与公证。
