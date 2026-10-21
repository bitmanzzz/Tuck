# Tuck

一个小巧的原生 macOS 菜单栏管理工具。把用不到的菜单栏图标收起来，需要时一键打开。

[English](README.md)

- **小**：约 1 MB，通用二进制（Apple 芯片和 Intel），没有第三方依赖。
- **原生**：Swift、AppKit 和 SwiftUI，不用 Electron，也不用网页视图。
- **支持 macOS 14 Sonoma 及以上**，包括 macOS 15 Sequoia 和 macOS 26 Tahoe。

## 功能

- "隐藏"和"始终隐藏"两个分区，用分隔线划分。分隔线和普通图标一样，按住 ⌘ 就能拖动。
- 显示隐藏图标的方式：点击 Tuck 图标、全局快捷键、悬停或点击菜单栏空白处、在菜单栏上滚动。
- **Tuck Bar**：在菜单栏下方弹出的面板，列出隐藏的图标。在有刘海的屏幕上默认使用。
- 布局编辑器：在"显示""隐藏""始终隐藏"三行之间拖动图标。
- 自动重新隐藏：鼠标离开菜单栏后、经过一段时间后，或切换应用时。
- 登录时启动。支持简体中文和英文。

## 安装

1. 从 [Releases](https://github.com/bitmanzzz/Tuck/releases) 下载 `Tuck-x.y.z.zip` 并解压。
2. 把 `Tuck.app` 拖到"应用程序"文件夹。
3. Tuck 没有经过 Apple 公证，第一次打开会被系统拦截。任选一种方式放行：
   - 先打开一次，然后到 **系统设置 → 隐私与安全性**，点击 **仍要打开**；
   - 或者在终端运行 `xattr -dr com.apple.quarantine /Applications/Tuck.app`。

## 使用

Tuck 会在菜单栏添加两个图标：Tuck 图标（‹）和它左边的一条细分隔线（|）。

1. 按住 ⌘，把想隐藏的图标拖到分隔线左边。
2. 点击 Tuck 图标显示或收起它们。按住 ⌥ 点击显示"始终隐藏"分区，右键点击打开菜单。
3. 在 **设置** 里配置快捷键、触发方式和布局（右键点击 Tuck 图标进入）。

第一次启动时，Tuck 图标左边的所有图标都会被隐藏。打开 **编辑布局…**，或按住 ⌘ 拖动，把需要常驻的图标拖回来。

### 权限

| 权限 | 用途 | 是否必需 |
| --- | --- | --- |
| 辅助功能 | 识别、打开和移动其他 App 的图标；Tuck Bar；布局编辑器；悬停和点击触发 | 基础隐藏之外的功能都需要 |
| 屏幕录制 | 在 Tuck Bar 和布局编辑器里显示图标的真实样子 | 可选，不授权时显示 App 图标 |

Tuck 不会录制或上传你的屏幕。

## 从源码构建

需要 Xcode 命令行工具（Swift 6）。

```sh
./scripts/setup-signing.sh      # 可选，只需一次：固定签名，重新编译后不用重新授权
./scripts/build-app.sh          # 构建通用版本到 build/Tuck.app
ARCHS=arm64 ./scripts/build-app.sh   # 只构建 arm64，更快
open build/Tuck.app
```

`PACKAGE=1 VERSION=1.2.3 ./scripts/build-app.sh` 会额外生成 `dist/Tuck-1.2.3.zip`。推送 `v*` 标签会自动构建并发布 GitHub Release。把 `setup-signing.sh` 输出的 `SIGNING_P12_BASE64` 和 `SIGNING_P12_PASSWORD` 加到仓库的 Secrets 里，发布版本的签名就能保持一致，用户升级后不用重新授权。

## 实现原理

- **隐藏**：分隔线是一个 `NSStatusItem`。收起分区时，把它的长度设为 10000pt，左边的图标就被挤出屏幕。
- **识别图标**：从 WindowServer 读取菜单栏图标窗口及其位置。macOS 26 起这些窗口都归控制中心所有，所以 Tuck 通过辅助功能接口（`AXExtrasMenuBar`）把每个窗口对应到所属 App。
- **移动图标**：模拟一次 ⌘ 拖拽，和手动操作一样。事件直接指定图标所在的窗口，所以被刘海挡住或在屏幕外的图标也能移动。
- **打开图标**：先展开分区，再通过辅助功能"按下"这个图标。
- **图标截图**：用 ScreenCaptureKit 截取图标窗口，屏幕外的也能截到。

## 已知限制

- Tuck 用了几个 CoreGraphics 私有函数读取菜单栏窗口，未来的 macOS 版本可能导致失效。

## 致谢

灵感来自 Jordan Baird 的 [Ice](https://github.com/jordanbaird/Ice)。Tuck 是独立实现。

## 许可证

[MIT](LICENSE)
