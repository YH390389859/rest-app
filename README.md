# Rest

一个参考 [Stretchly](https://github.com/hovancik/stretchly) 思路、用原生 Swift + AppKit/SwiftUI 写的 macOS 休息提醒菜单栏应用。

针对三个具体痛点做了重做：

1. **看视频时进入休息，全屏下没法暂停视频** → 自动识别"谁在占用音频 / 谁在播放"，一键（或自动）暂停。
2. **界面太朴素** → 接入必应每日壁纸（4K），跨全屏覆盖。
3. **倒计时结束直接跳到下一轮，和界面显示不符** → 支持"停留等按钮"或"全透明遮罩 + 任意键鼠动作才继续"。

## 构建与运行

```bash
./build.sh                 # 产出 build/Rest.app
open build/Rest.app        # 直接运行（或拖到 /Applications）
```

要求 macOS 14+、Xcode 命令行工具。打包是 ad-hoc 签名；"登录时自动启动"需要把 App 放到 `/Applications` 才能真正生效。

调试用参数：

```bash
./build/Rest.app/Contents/MacOS/Rest --preview              # 启动后立即弹一次休息界面
./build/Rest.app/Contents/MacOS/Rest --render /tmp/ui.png   # 把界面离屏渲染成 PNG（不需要录屏权限）
```

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

它和键盘上的媒体键效果等价，但**不需要辅助功能授权**，也不会像 AppleScript 那样弹出「自动化」权限申请、更不会因为某个 App 没开 AppleScript 支持而失败。

降级链路：`MediaRemote pause` → 校验 `isPlaying == false` → 失败则模拟 `NX_KEYTYPE_PLAY` 媒体键（这条路需要辅助功能授权，所以只做兜底）。休息结束时只恢复"原本被我们暂停的那个 App"，用户自己又开了别的视频则不动。

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
  Scheduler.swift             工作/休息状态机（基于 deadline，非累加计数）
  AudioActivityMonitor.swift  CoreAudio 进程对象枚举
  MediaRemoteBridge.swift     MediaRemote 私有框架的 dlsym 封装
  MediaController.swift       查询 / 暂停 / 恢复，含媒体键兜底
  WallpaperService.swift      必应壁纸下载与缓存
  BreakViewModel.swift        休息界面状态
  BreakView.swift             SwiftUI 休息界面
  BreakWindowController.swift 跨屏遮罩窗口 + 输入捕获
  BreakCoordinator.swift      把上面这些串起来
  StatusBarController.swift   菜单栏图标与菜单
  SettingsView.swift          设置窗口
  DebugRender.swift           离屏渲染调试
```

计时用「目标时间戳」而不是自增计数器，睡眠唤醒后不会漂移。空闲超过 2 分钟会跳过这次休息（可在设置里关掉）。

界面上的倒计时不是自己算的：`Scheduler` 每 0.25s 通过 `onBreakTick(remaining, total)` 把剩余时间推给 `BreakCoordinator`，后者写进 `BreakViewModel.remaining`。这样状态机和界面只有一个数据源，不会出现"环在转、数字不动"或反过来。

## 已知边界

- `MediaRemote.framework` 是私有 API，随系统版本有变化风险；失效时会自动退化为媒体键模拟。
- 遮罩捕获到输入时，那一下点击/按键会被吞掉（本来就是"我回来了"的确认动作）。
- 主要针对单用户本机使用，未做沙盒与公证。
