[English](README.md) | **简体中文**

# OmniDock

把 Dock 预览、点击隐藏、窗口分屏、剪贴板和 Finder 右键这些常用操作，放进一个 Mac 应用里，不用为每件小事都装一个工具。

刚从 Windows 换过来，也能保留一些熟悉的窗口操作习惯。

[下载](https://github.com/quanzhankeji/OmniDock/releases/latest) · [官网](https://omnidock.app/zh/) · [使用帮助](SUPPORT.md)

免费开源 · macOS 12.3 或更高版本 · 支持 Apple 芯片和 Intel Mac

## 看看这些功能怎么用

### 01 · Dock 窗口预览

窗口还没切过去，就能先看见。把鼠标停在运行中的应用图标上，点预览切到目标窗口，也可以直接关闭窗口。拖文件时，先拖到缩略图上，就能把目标窗口带到前台。

https://github.com/user-attachments/assets/5033facb-ec33-4f57-8e00-a177198431e7

### 02 · 应用快捷键

给常用应用各设一组快捷键，没打开就启动，已经运行就切到前台。开启重复触发时隐藏后，再按一次还能把应用收起来。演示中的按键组合只是示例，可以按自己的习惯设置。

https://github.com/user-attachments/assets/38aa4f77-c2ba-4e10-bcc8-c480344b7681

### 03 · 窗口布局

把窗口拖到设好的屏幕区域，松手就能摆好。也可以用快捷键或绿色按钮的布局菜单，完成半屏、四角、三分屏、多显示器移动和自定义布局。

https://github.com/user-attachments/assets/3713f313-0cb9-4976-926e-99d441bc82ae

### 04 · 剪贴板历史

刚才复制的内容，不用再找一遍。开启本机历史后，按 `Command-Shift-C` 搜索保存过的文字、富文本、链接、图片和文件记录。不想保留的，可以单独删除或全部清空。

https://github.com/user-attachments/assets/ea674a12-7c00-4d44-a994-a9bd7fadf6aa

### 05 · Finder 右键操作

在支持的 Finder 文件夹里，点右键就能新建空白文件、复制一个或多个路径、显示隐藏项目，或者用指定应用打开选中内容。

https://github.com/user-attachments/assets/85807a3b-611c-4151-946e-8ae6f29318cd

### 06 · 菜单栏整理

按住 `Command`，把不常用的图标拖到分界线后面。需要时点一下展开，用完手动收起，也可以设为 5–60 秒后自动收起。哪些图标放进去，由你决定，不会自动分类。

https://github.com/user-attachments/assets/7f29d5c2-4206-4151-9332-691f6e9a89df

### 还有这些顺手的窗口操作

- **再点一次就隐藏：**点击运行中的应用图标，把它带到前台；再点一次就隐藏。也可选择最小化与恢复，作用于该应用可控制的普通窗口。
- **直接切换窗口：**用 `Option-Tab` 选择单个窗口，或给系统原生 `Command-Tab` 加上窗口预览。

界面支持简体中文和英文，语言和深浅外观都能跟随系统，也可以自己选。macOS 13 及以上还可以设置登录后自动启动。

部分窗口无法获取画面或调整大小；隐藏、最小化的窗口可能使用近期静态图像或文字状态。由 File Provider 管理的云盘文件夹，也可能不显示 Finder 扩展菜单。开启方法和具体限制见[使用帮助](SUPPORT.md)。

## 安装

1. 从 [GitHub Releases](https://github.com/quanzhankeji/OmniDock/releases/latest) 下载最新版 **DMG**，把 OmniDock 拖进“应用程序”。也提供 ZIP 应用归档。
2. 启动 OmniDock，点击菜单栏里的 `OD`，开启你用得上的功能。

GitHub 官方安装包同时支持 Apple 芯片和 Intel Mac，经过 Developer ID 签名和 Apple 公证。更新安装前会校验 GitHub 文件摘要和应用签名；只读或不可写的安装位置会改用 DMG 手动更新。

## 权限与隐私

用到哪些功能，再开它们需要的权限。

| 权限 | 用途 |
| --- | --- |
| 辅助功能 | Dock 与窗口控制、应用快捷键、窗口布局，以及可选的剪贴板自动粘贴 |
| 输入监控 | Dock 点击、Option-Tab 和窗口拖拽区域 |
| 屏幕录制 | 生成实时或静态窗口缩略图 |
| Finder 扩展与文件夹授权 | 提供右键菜单，并在你授权的文件夹里新建文件 |

无需账号，不含数据分析或广告 SDK。设置和可选的剪贴板历史留在本机，预览图像只保存在内存中。应用会访问 GitHub 检查更新，并下载你确认的安装包，不会上传上述内容。

剪贴板历史默认关闭。只有被来源应用明确标记为临时、机密或自动生成的条目才会被跳过，不能识别所有敏感内容。具体存储方式和限制见[隐私政策](PRIVACY.md)。

## 构建与贡献

项目使用兼容 Swift 5.9 的工具链和 Apple 系统框架，没有第三方软件包依赖。构建包含 Finder Sync 扩展的完整应用，还需要 Xcode 和 Apple Development 签名团队。

在仓库根目录运行：

```bash
swift test
./script/build_and_run.sh
```

第二条命令会构建完整应用，将其安装到 `/Applications` 并启动。暂存构建、验证、签名选项和项目结构见[开发文档](docs/DEVELOPMENT.md)，正式分发步骤见[发布文档](docs/RELEASING.md)。

提交改动前请阅读[贡献指南](CONTRIBUTING.md)。代码和文档贡献需要接受[贡献者许可协议](CLA.md)。

遇到问题请看[使用帮助](SUPPORT.md)。安全漏洞请按 [SECURITY.md](SECURITY.md) 中的私密流程报告，不要提交公开 issue。

## 开源协议

除文件另有说明外，源代码和文档仅以 GNU GPL version 3（`GPL-3.0-only`）授权。GitHub 官方 Release 二进制也以 GPL v3 分发。完整许可和版权声明见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

App Store 和其他 Developer ID 分发版本可能由成都全栈科技有限公司按单独的最终用户条款提供，以具体安装包随附条款为准。双重许可模式和早期 MIT 许可版本的说明见 [LICENSING.md](LICENSING.md)。

源代码许可不授予 OmniDock 名称、标志或应用图标的使用权，详见[商标政策](TRADEMARKS.md)。
