# VolumeBridge

原生 macOS 外接磁盘与 NTFS 读写管理工具，使用 SwiftUI、NTFS-3G 和 FUSE-T。支持简体中文、英文和日文，右上角齿轮菜单 →「语言…」可切换。

## 构建与使用

需要 macOS 14 或更高版本及 Xcode Command Line Tools。已在 Apple Silicon 本机验证。

```sh
brew install autoconf automake libtool pkgconf libgcrypt
python3 Source/build.py
open VolumeBridge.app
```

完整构建会下载并校验官方 FUSE-T 安装包，将框架和 NTFS-3G 驱动打包进应用。已有驱动时可用 `python3 Source/build.py --ui-only` 更新界面。

在「系统设置 → 隐私与安全性 → 完整磁盘访问」中添加并启用 VolumeBridge。切换挂载模式会通过 macOS 请求管理员授权。读写失败后尝试恢复系统只读挂载；切换或推出前关闭该磁盘上的文件和复制任务。

列表保持紧凑表格布局，NTFS 优先，同组按名称自然排序。容量从实际挂载路径读取，12 秒自动刷新。更多菜单可以查看磁盘详情。

## 本地签名与兼容

GitHub 克隆版默认使用临时签名，可以通过 `VOLUMEBRIDGE_SIGNING_IDENTITY`（证书 SHA-1）和 `VOLUMEBRIDGE_BUNDLE_ID` 配置稳定签名，具体命令见英文 README。

这台 Mac 的构建继续使用原有本地证书和 Bundle ID，保留完整磁盘访问的身份关联。已有挂载路径 `/Volumes/NTFSDesk-diskXsY` 保留兼容，应用显示名称为 VolumeBridge。本机证书和编译后的 `.app` 已列入 `.gitignore`。

FUSE-T 使用本机 NFS 服务，Finder 可能将卷显示为网络卷。系统和驱动的原始诊断信息保留原文。

## 测试

```sh
python3 Tests/test_regressions.py
python3 Source/test_localization.py
```

回归测试使用模拟设备与命令，语言测试检查三种语言资源和错误提示。应用里的「验证读写」在独立的 64 MB 镜像中进行实际读写测试。

## 发布到 GitHub

仓库建议命名为 `volume-bridge`。提交源码、翻译、测试、构建脚本及第三方许可证；编译后的应用通过 GitHub Releases 单独发布。第三方组件保留其上游许可证，见 `THIRD_PARTY_NOTICES.md` 与 `Licenses/`。
