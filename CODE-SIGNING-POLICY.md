# 代码签名策略

本文是 Rest 发布产物的签名规则说明，也是向签名服务（SignPath Foundation）申请时
提供的 code signing policy 页面。

## 签什么

每个正式版本（`v*` tag）都会对下列文件做 Authenticode 签名，算法 SHA-256 并带
RFC 3161 时间戳：

| 产物 | 平台 | 说明 |
|---|---|---|
| `Rest-<version>-win-x64-setup.exe` | Windows | Inno Setup 安装器 |
| 安装器内的 `Rest.exe` | Windows | 主程序，先于安装器单独签名再打包 |
| `unins000.exe` | Windows | 卸载器，由安装器内嵌已签名副本生成 |
| `Rest.app`（含 `Rest` 可执行文件） | macOS | 本地固定证书签名，见 `macos/tools/make-signing-cert.sh` |

不签名：`*.dll`、`*.json`、壁纸缓存等数据文件；macOS 的 `.dmg` / `.zip` 容器
本身不含签名（对内层 `.app` 签名）。

## 谁可以签

- 仅 GitHub Actions 在**本仓库** `build.yml` 工作流中构建的产物可以签名。
- 签名请求由仓库所有者（YH390389859）在签名服务上人工批准，不存在自动批准。
- 私钥不落地：Windows 签名通过签名服务的 HSM 完成，本地与 CI 都不持有私钥。

## 构建来源要求

- 构建只允许在 GitHub 托管的 runner 上执行（`windows-latest` / `macos-26-intel`），
  不接受自托管 runner 或本地构建的二进制送签。
- 送签的二进制必须来自本仓库对应 tag 的提交，版本号取自仓库根 `VERSION`，
  CI 会校验 tag 与 `VERSION` 一致。
- 每次发版都会跑 `windows/tests/Rest.Core.Tests`（节奏模型 22 个用例）与
  `Rest.exe --self-test`，测试不通过则不进入签名环节。

## 产物校验

- 用户可用 `Get-AuthenticodeSignature .\Rest.exe` 查看签名状态与签名者。
- 每个版本的 `Rest.exe` 文件版本号必须等于 `VERSION`，CI 中对安装器与主程序
  都做了断言。
- 已签名的安装器在安装后写入的卸载器同样带签名，避免"能装不能卸"。

## 变更

本策略的修改会在提交历史中可见，并与发版说明一同发布。
