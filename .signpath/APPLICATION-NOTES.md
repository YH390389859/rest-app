# SignPath Foundation 申请材料

本文件是填写 [signpath.org/apply](https://signpath.org/apply) 表单用的**答案底稿**，逐字段可直接粘贴。
不包含任何凭据（组织 ID、项目 slug、API token 一律不记录在此，也不进仓库）。

## 一、资格自检（已核对）

| Foundation 条款 | 要求 | 本仓库现状 |
|---|---|---|
| 开源许可证 | OSI 认可、无商业双许可 | ✅ MIT（GitHub 识别 `spdx_id: MIT`），无商业授权条款 |
| 无专有组件 | 不得含非开源自有代码 | ✅ 全部源码在本仓库；.NET 运行时与 WPF 属 System Libraries |
| 持续维护 | 项目在活跃开发 | ✅ 最近提交 2026-11-28 |
| 已发布 | 必须以要签名的形式发布过 | ✅ `v1.1.0` 已含 `Rest-1.1.0-win-x64-setup.exe` 等 4 个产物 |
| 有文档 | 下载页/商店页描述功能 | ✅ README 与 Release 说明 |
| 公开仓库 | 私有仓库不适用 | ✅ `visibility: public` |
| 构建来源 | 仅 GitHub 托管 runner，不接受本机打的包 | ✅ `.github/workflows/build.yml`，`windows-latest` + `macos-26-intel` |
| 签名策略页 | 需公开说明签什么、谁能签 | ✅ `CODE-SIGNING-POLICY.md` |
| 下载页声明 | 页面上写明使用 SignPath Foundation 签名 | ✅ README「Code signing」小节 |
| 不收集用户数据 | 若有外传须有隐私政策并在安装时展示 | ✅ 无遥测；唯一外连是取必应壁纸（只下载不上传） |
| 提供卸载 | 必须有卸载途径 | ✅ 安装器写入 `unins000.exe`，且同样签名 |
| 2FA | SignPath 与代码托管账号都要开 | ⬜ 提交前自行确认 |

## 二、表单逐字段答案

**Project name**

```
Rest
```

**Repository URL**

```
https://github.com/YH390389859/rest-app
```

**Project homepage / Website**

```
https://github.com/YH390389859/rest-app
```

**Download page URL**

```
https://github.com/YH390389859/rest-app/releases/latest
```

**Code signing policy URL**（若表单拆成单独字段）

```
https://github.com/YH390389859/rest-app/blob/main/CODE-SIGNING-POLICY.md
```

**License**

```
MIT
```

**Primary language**

```
Swift, C# (.NET 8)
```

**Build system**

```
GitHub Actions (GitHub-hosted runners only: windows-latest, macos-26-intel)
```

**Maintainer type**

```
Individual
```

**Company name** / **Wikipedia page** / **Privacy policy URL**

```
(留空 —— 个人维护者、无公司主体、无维基条目、不收集用户数据因而无隐私政策文档)
```

**Email**（用能正常收信的地址，**不要**用 `@users.noreply.github.com`）

```
<你的常用邮箱>
```

**Short description**

```
Rest is a cross-platform break reminder that pauses whatever video is playing, covers every display with a translucent countdown overlay, and resumes playback when the break ends.
```

**Project description**

```
Rest is a desktop break reminder for macOS and Windows. At a configurable interval it
pauses the media currently playing — through MPNowPlayingInfoCenter on macOS and the
System Media Transport Controls (SMTC) on Windows — dims every display with a translucent
overlay carrying the countdown, and resumes playback when the break is over. It fetches
Bing's daily wallpaper as the break backdrop and handles per-monitor DPI on mixed-scaling
multi-monitor setups.

The macOS build is a native Swift/AppKit application built with SwiftPM; the Windows
build is a .NET 8 WPF application. Both are built by GitHub Actions on GitHub-hosted
runners only, from the commit of the release tag, and the tag is validated against the
repository's VERSION file before any artifact is produced. Each GitHub release carries
both platforms' packages. The Windows package is an Inno Setup installer that installs
per-user without administrator rights and ships a signed uninstaller.

The application collects no user data and sends nothing to the maintainer. The only
outbound request is downloading the Bing daily wallpaper image.
```

## 三、提交时的坑

- **邮箱**：`noreply` 地址收不到验证信，审核还会用它联系补材料。
- **不要编数据**：没有媒体报道、没有下载量就照实写，Foundation 会核对仓库。
- **下载页必须是公开可打开的**：`/releases/latest` 比 tag 页稳，永远是当前版。
- 提交后**不要**把组织 ID、项目 slug、API token 写进 README、issue 或任何公开位置；token 等同签名权限。

## 四、批准后的配置（代码已就绪，只需填 4 个值）

1. 登录 signpath.io → 建 Project，slug 建议 `rest-app`；
2. 建 Signing policy，slug 建议 `release-signing`；
3. 把 `.signpath/artifact-configurations/app.xml` 与 `installer.xml` 的内容贴进项目的 Artifact Configurations；
4. 装 SignPath GitHub App，只授权 `rest-app` 仓库；
5. 开 2FA（SignPath + GitHub 都要）；
6. 建 API token（submitter 角色），存到仓库 Secrets：

| 类型 | 名称 | 值 |
|---|---|---|
| variable | `SIGNPATH_ORGANIZATION_ID` | 组织 ID |
| variable | `SIGNPATH_PROJECT_SLUG` | `rest-app` |
| variable | `SIGNPATH_POLICY_SLUG` | `release-signing` |
| secret | `SIGNPATH_API_TOKEN` | submitter token |

`SIGNPATH_PROJECT_SLUG` 不填时，CI 里所有签名步骤会自动跳过（仍能出未签名包），所以可以先合并代码再补配置。

7. 打新 tag 触发流水线，在 SignPath 上**人工批准**这次签名请求；签完的包会回填进安装器再打便携包。
8. 验收：`Get-AuthenticodeSignature .\Rest.exe` 应为 `Valid`，签名者 `CN=SignPath Foundation`。
