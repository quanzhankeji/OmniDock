[English](README.md) | **简体中文**

# OmniDock

OmniDock 是一款本机优先的 macOS 工具，用于更快速地切换窗口、控制应用，并增强 Finder、剪贴板、窗口布局和菜单栏整理工作流。

## 功能

- 将鼠标停在 Dock 应用图标上，预览该应用已经打开的窗口。
- 点击正在运行的 Dock 应用图标将其前置；再次点击当前前台应用即可隐藏窗口，且不会在 Dock 中生成最小化窗口图标。
- 可选择使用最小化/恢复，替代重复点击 Dock 图标时的隐藏/显示行为。
- 点击预览缩略图，准确聚焦对应窗口。
- 将文件拖到预览缩略图上，OmniDock 会前置目标窗口并让你继续完成拖放。
- 使用系统原生 Command-Tab 切换器时，可选择显示当前选中应用的静态窗口预览。
- 可使用 Alt-Tab（Option-Tab）在单个窗口之间切换，并通过静态预览执行选择、关闭窗口和退出应用等操作。
- 为不同应用设置全局快捷键，通过同一套切换逻辑启动、前置或隐藏应用。
- 使用全局快捷键、绿色按钮布局菜单或自定义拖拽区域，调整桌面最前方窗口的大小和位置。
- 可在 Finder 右键菜单中加入复制路径、新建空白文件、显示或隐藏隐藏文件，以及用指定应用打开所选项目等可配置命令。
- 可启用本机剪贴板历史，通过 `Command-Shift-C` 搜索文字、富文本、链接、图片和文件。
- 将不常用的菜单栏图标收纳到可展开的分界线后方，支持手动展开和自动隐藏。
- 可选择 English、简体中文或跟随系统语言，并使用浅色、深色或跟随系统外观。
- 检查正式更新，并在安装前验证 GitHub 摘要和 Developer ID 签名。
- 避开浏览器标签页导航快捷键，让这些快捷键继续由浏览器处理。

OmniDock 不包含数据分析、广告 SDK 或第三方软件包，仅使用 Apple 系统框架。

## 系统要求

- macOS 12.3 或更高版本
- 辅助功能权限：用于 Dock 命中检测、应用与窗口控制、应用快捷键和可选的窗口调整
- 输入监控权限：用于 Dock 点击检测、可选的 Alt-Tab 窗口切换器和窗口拖拽触发区域
- 屏幕录制权限：用于生成窗口缩略图，包括实时画面和一次性静态快照
- Finder 扩展权限和一次性目标文件夹授权：用于可选的 Finder 命令

## 下载

正式版本可从 [GitHub Releases](https://github.com/quanzhankeji/OmniDock/releases/latest) 下载。标准安装请下载 `OmniDock-<version>.dmg`，便携应用归档请下载 `OmniDock-<version>.zip`。两者都包含同一份适用于 Apple 芯片和 Intel Mac 的 Universal 应用，并经过 Developer ID 签名和 Apple 公证。GitHub 还会为每个版本提供对应源代码的 ZIP 和 TAR.GZ 归档。

OmniDock 会在启动后异步检查 GitHub Releases。发现新的已签名版本时，OmniDock 可以下载并验证更新，替换可写安装位置中的旧版本，然后重新启动应用。如果应用从只读磁盘映像、App Translocation 或其他不可写位置运行，则会改用 DMG 手动安装流程。你也可以在设置页中手动检查更新。

使用 Homebrew 安装：

```bash
brew tap quanzhankeji/tap
brew install --cask omnidock
```

## 构建与运行

```bash
./script/build_and_run.sh
```

此脚本会构建包含 Finder Sync 扩展的完整 `OmniDock.app`，将其安装到 `/Applications` 并启动。当系统中只有一个 Developer ID Application 身份时，本地 Release 构建会使用该稳定身份重新签名，使已有的 macOS 隐私权限在重复构建后仍能保持关联。

构建完整应用需要 Xcode、Apple Development 团队和兼容 Swift 5.9 的工具链。如果没有 Developer ID 身份，安装包会保留 Apple Development 签名。Developer ID 版本一旦安装，脚本会拒绝使用开发签名版本替换它，除非显式设置 `OMNIDOCK_ALLOW_SIGNING_IDENTITY_CHANGE=1`，因为更换签名身份会使 macOS 隐私权限失去关联。如果有多个 Developer ID 身份，请显式设置 `OMNIDOCK_LOCAL_DEVELOPER_IDENTITY`。

设置 `OMNIDOCK_APP_DIR` 可更改暂存目录。设置 `OMNIDOCK_BUILD_CONFIGURATION=debug` 可强制使用 Debug 构建。

将完整本地应用安装到 Applications：

```bash
./script/build_and_run.sh --install
```

也可以继续使用显式的 Finder 扩展安装别名：

```bash
./script/build_and_run.sh --install-finder-extension
```

## 窗口预览与应用控制

Dock 预览会展示 macOS 允许 OmniDock 识别的普通应用窗口。你可以通过预览卡片准确聚焦或关闭窗口、退出对应应用，也可以在拖动文件时前置目标窗口。关闭实时预览后会改用静态快照，降低资源占用。对于隐藏、最小化或暂时无法取得画面的窗口，OmniDock 可能显示近期静态图像或文字状态。

Dock 点击切换只处理已经运行的应用。短按后台应用图标会将其前置，再次点击当前最前方且可见的应用则会隐藏它。尚未启动的应用、长按和 Dock 图标排序仍由 macOS 处理。你也可以将这套行为改为最小化与恢复。

可选的 Command-Tab 预览只增强 macOS 原生应用切换器，不会替代它。独立的 Alt-Tab 窗口切换器使用 Option-Tab 在单个窗口之间导航，并使用静态预览。应用快捷键可以启动尚未运行的应用、前置后台应用，或隐藏已经位于前台的应用。

## Finder 右键扩展

Finder 扩展默认关闭。打开 `OD` > `设置` > `右键扩展`，然后开启“启用”。macOS 可能会打开扩展管理页面；请在那里启用 OmniDock，让 Finder 加载该菜单。

启用后，在 Finder Sync 可监控的本地文件夹空白处点击右键，可使用**复制路径**、可配置的**新建文件**子菜单，以及显示或隐藏隐藏文件的命令。默认包含文本和 Markdown，也可以在 OmniDock 设置中添加其他文件类型。右键点击所选项目时，可使用**复制路径**、隐藏文件显示命令，以及用指定应用打开所选项目的可选快捷操作。复制多个项目时，每条路径会单独占一行；新文件使用可用的 `NewFile.<extension>` 名称，不会覆盖已有文件。

OmniDock 会注册本地的 Desktop、Documents、Downloads，在对应目录存在时也会注册其 iCloud Drive 版本，以及你明确授权的其他文件夹。Finder 最终决定某个文件提供方管理的位置能否显示 Finder Sync 菜单，因此部分第三方云盘目录可能不会提供这些命令。

## 剪贴板历史

剪贴板历史默认关闭。打开 `OD` > `设置` > `剪贴板历史` 后启用。启用期间，OmniDock 会检查系统剪贴板变化，并把支持的内容保存在这台 Mac 上。按 `Command-Shift-C` 搜索历史记录，使用方向键选择项目，按 Return 将其重新复制；确认时按住 Option，可以粘贴到打开历史面板前处于活动状态的应用。

被来源应用明确标记为临时、隐藏或自动生成的剪贴板条目会被忽略。历史数量可设置为 1–999 条，并可在设置中删除单条记录或清空全部历史。

## 窗口调整

窗口调整是可选功能。打开 `OD` > `设置` > `窗口调整` 后启用，即可通过全局快捷键、悬停窗口绿色按钮时显示的布局菜单，或松开窗口时应用布局的拖拽触发区域，调整桌面最前方可缩放窗口的大小和位置。

内置布局包括半屏、四角、三分之一、三分之二、最大化、居中、恢复，以及在不同显示器之间移动窗口。自定义布局可以分别设置大小与位置、键盘快捷键和拖拽触发区域。全屏窗口、系统面板，以及被应用限制移动或缩放的窗口，仍以 macOS 和对应应用的实际行为为准。

## 菜单栏图标整理

打开 `OD` > `设置` > `任务栏图标`，启用 Hidden Bar，即可将不常用的菜单栏图标收纳到可展开的分界线后方。按住 Command，将菜单栏图标拖过分界线完成排列；之后可以手动展开，或让 OmniDock 在设置的延迟后自动隐藏这些图标。

此功能不需要额外的隐私权限。部分由 macOS 控制的系统菜单栏项目无法移动。

仅启动暂存应用包：

```bash
./script/build_and_run.sh --stage
```

运行测试套件：

```bash
swift test
```

只组装、签名并验证暂存应用，不安装也不启动：

```bash
./script/build_and_run.sh --verify
```

## 开发

项目结构、核心交互流程和回归检查清单请参阅 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

维护者可在 [docs/RELEASING.md](docs/RELEASING.md) 中查看通用的签名与分发说明。

欢迎按照 [CONTRIBUTING.md](CONTRIBUTING.md) 中的流程参与贡献。代码和文档贡献需要接受[贡献者许可协议](CLA.md)。

## 隐私

OmniDock 在你的 Mac 本机运行。偏好设置、快捷键绑定和可选的剪贴板历史均存储在本机。快捷键绑定包含所选应用的名称、Bundle Identifier、应用 URL 或路径、按键组合和启用状态。剪贴板历史只有在用户主动开启后才会工作，并且可以随时清空。

为便于短时间显示隐藏窗口预览，一次性预览快照缓存会在捕获 45 秒后过期。如果缓存过期时预览仍处于打开状态，OmniDock 会在下一次预览有效性检查时释放对应的显示图像引用。预览图像不会写入磁盘。OmniDock 不收集或传输个人数据。

Finder 的“新建文件”命令只会把用户选择的目标文件夹临时传递给主应用，并在请求被消费或过期后移除。OmniDock 不会扫描 Finder 文件夹，也不会请求宽泛的文件系统访问权限。

更新检查器会向 GitHub 的公开 Releases API 发送标准 HTTPS 请求，其中不包含 OmniDock 设置、剪贴板内容、窗口信息或其他用户数据。下载的更新只有在 SHA-256 摘要与 GitHub 记录一致，并且代码签名身份与现有 OmniDock 一致时才会安装。

完整隐私政策请参阅 [PRIVACY.md](PRIVACY.md)。

## 支持

设置说明、故障排查和支持方式请参阅 [SUPPORT.md](SUPPORT.md)。

潜在安全漏洞请通过 [SECURITY.md](SECURITY.md) 中的私密流程报告，不要提交公开错误报告。

## 许可

公开源代码仅以 GNU GPL version 3（`GPL-3.0-only`）授权。GitHub 官方 Release 二进制也以 GPL v3 分发。App Store 和其他 Developer ID 二进制可能由成都全栈科技有限公司根据单独的最终用户条款提供。双重许可模式及早期 MIT 许可版本的处理方式请参阅 [LICENSING.md](LICENSING.md)。

GPL 源代码许可不授予 OmniDock 名称、标志或应用图标的使用权。详情请参阅 [TRADEMARKS.md](TRADEMARKS.md)。
