# winget 清单（草稿 + 留档）

这里是提交到 [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) 的清单，
目录结构与该仓库一致，方便整段复制过去。

## 提交位置

清单不是提交到本项目，而是 **PR 到微软的 `microsoft/winget-pkgs` 仓库**，路径固定为：

```
manifests/<Publisher 首字母小写>/<Publisher>/<PackageName>/<Version>/
→ manifests/y/yanghui/Rest/1.1.0/
```

三份文件缺一不可：`yanghui.Rest.yaml`（版本）、`yanghui.Rest.installer.yaml`（安装器）、
`yanghui.Rest.locale.en-US.yaml`（描述信息）。

## 每次发版要改两处

1. 三份文件里的 `PackageVersion` 与目录名改成新版本号
2. `installer.yaml` 里的 `InstallerUrl` 与 `InstallerSha256`

SHA256 不用下载安装包算，GitHub API 直接给：

```bash
curl -s https://api.github.com/repos/YH390389859/rest-app/releases/latest \
  | python -c "import json,sys;[print(a['name'],a.get('digest')) for a in json.load(sys.stdin)['assets']]"
```

**注意**：接入 SignPath 之后安装包会被重签，字节变了 hash 也变，所以「签名完成后的那个
setup.exe」才是清单要指向的文件。现有 CI 是先打包后签名再上传，顺序是对的，只要清单
在 Release 产出之后再更新即可。

## 本地校验

```powershell
winget validate --manifest windows\packaging\winget\manifests\y\yanghui\Rest\1.1.0
```

## 提交方式

- **图形化**：[wingetcreate](https://github.com/microsoft/winget-create)
  `wingetcreate update yanghui.Rest --version <新版本> --urls <setup.exe 链接>` 会自动算 hash、校验、
  建 fork 并开 PR
- **手工**：fork `microsoft/winget-pkgs`，把本目录的 `manifests/y/yanghui/Rest/<version>/` 原样放进去，
  开 PR。首次贡献需要签微软 CLA（PR 里点一下即可）

合并后约几小时到几天内 `winget install yanghui.Rest` 可用。
