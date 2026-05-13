---
name: macos-app-scaffold
description: >
  Scaffold a production-ready native macOS app project (SwiftUI + SwiftData + SPM)
  with auto-update via GitHub Releases, dev/release build scripts, in-app localization,
  menu-bar persistence, and a landing-page template. Use when the user says:
  "new macos app", "scaffold mac app", "create macos app", "swiftui scaffold",
  "新建 mac 应用", "脚手架", "生成 macOS 项目", "搭一个 swift app",
  or asks to start a fresh native macOS app project.
---

# 创建 macOS 应用项目

生成生产级原生 macOS 应用脚手架，基于 [TaskTick](https://github.com/lifedever/TaskTick) 这类已上线项目沉淀的最佳实践。

## 用法

```
/macos-app-scaffold <应用名> [--bundle-id com.example.app] [--github user/repo]
```

- `应用名`：必填，PascalCase 格式（如 `MyApp`）
- `--bundle-id`：可选，默认 `com.example.<应用名>`（首次使用请改为你自己的反向域名）
- `--github`：可选，用于自动更新的 GitHub 仓库，格式 `<owner>/<repo>`

## 生成内容

生成以下项目结构。先询问用户创建位置（默认：`~/<应用名>-app/`）。

### 项目结构

```
<应用名>-app/
├── Package.swift
├── Sources/
│   ├── App/
│   │   ├── <应用名>App.swift          # @main，多窗口 Scene，ModelContainer
│   │   ├── AppDelegate.swift          # Cmd+Q → 隐藏到菜单栏，shouldReallyQuit
│   │   └── Localization.swift         # L10n.tr() 辅助方法 + LanguageManager
│   ├── Engine/
│   │   ├── UpdateChecker.swift        # GitHub Releases API，DMG 下载、安装、重启
│   │   └── NotificationManager.swift
│   ├── Models/
│   │   └── （空目录，用户自行添加 SwiftData 模型）
│   ├── Views/
│   │   ├── Main/
│   │   │   └── MainWindowView.swift   # NavigationSplitView 分栏布局
│   │   ├── MenuBar/
│   │   │   └── MenuBarView.swift      # MenuBarExtra 弹窗内容
│   │   ├── Settings/
│   │   │   └── SettingsView.swift     # TabView：通用、更新、关于
│   │   └── Components/
│   │       ├── GlassCard.swift        # macOS 26 液态玻璃 + 低版本降级
│   │       └── PointerCursor.swift    # .pointerCursor() 小手光标修饰符
│   ├── Localization/
│   │   ├── en.lproj/
│   │   │   └── Localizable.strings
│   │   └── zh-Hans.lproj/
│   │       └── Localizable.strings
│   └── Resources/
│       └── AppIcon.icns               # 占位图标，用户自行替换
├── Tests/
│   └── <应用名>Tests.swift
├── scripts/
│   ├── build-dev.sh                   # 开发版构建：灰色图标、独立 bundle ID
│   └── release.sh                     # 发布版：arm64 + x86_64 DMG、上传 GitHub Release
├── docs/
│   └── index.html                     # 静态落地页，GitHub Pages 自动部署
├── .gitignore
├── LICENSE                            # 询问用户选择的开源协议
├── CLAUDE.md                          # Claude Code 项目说明
└── .claude/
    └── skills/
        └── release/
            └── SKILL.md               # /release <version> 发版技能
```

### 实现规范

生成代码时严格遵循以下规则：

#### Package.swift
- swift-tools-version: 6.0
- `defaultLocalization: "en"`
- `platforms: [.macOS(.v14)]`
- Resources: `.process("Localization")`

#### 应用入口（<应用名>App.swift）
- 多窗口：`Window`（主窗口）+ `MenuBarExtra` + `Settings` + 编辑器窗口等
- `ModelContainer` 数据库隔离：dev bundle ID → `<appname>-dev.store`，正式版 → `default.store`
- `.commands {}` 完整菜单结构：
  - appInfo 后：关于、检查更新、支持开发者（heart 图标）
  - newItem：应用相关操作
  - toolbar 后：刷新
  - help：GitHub 主页、报告问题

#### AppDelegate
- `shouldReallyQuit` 静态标志位
- `applicationShouldTerminate`：如果 shouldReallyQuit 为 false → 关闭窗口、隐藏到菜单栏、返回 `.terminateCancel`
- 只有菜单栏的「退出」按钮才设置 `shouldReallyQuit = true`

#### UpdateChecker（自动更新）
- 轮询 GitHub Releases API：`https://api.github.com/repos/<owner>/<repo>/releases/latest`
- 比较 semver 版本号，弹出 UpdateDialogView：跳过此版本 / 稍后提醒 / 立即安装
- 下载 DMG → 挂载 → 复制 .app 到 /Applications → 卸载 → 通过 `open` 重新启动
- Dev 版（bundle ID 以 `.dev` 结尾）跳过更新检查
- 可配置定期检查间隔（默认 24 小时）

#### 本地化（Localization）
- `L10n.tr("key")` 和 `L10n.tr("key", arg)` 辅助方法
- `LanguageManager` 单例，使用 `@AppStorage("appLanguage")`
- `.localized()` 视图修饰符，语言切换时触发重新渲染
- Bundle.module 大小写不敏感 `.lproj` 文件夹查找
- 两种语言：en、zh-Hans，所有字符串必须在两个文件中都添加

#### SettingsView（设置窗口）
- `TabView` 每个 tab 使用 `Form { ... }.formStyle(.grouped)`
- `.frame(width: 460).fixedSize(horizontal: false, vertical: true)` 宽度固定、高度自适应
- Tab 页：通用（外观、语言、开机启动）、更新（自动检查、频率、立即检查）、关于（版本、构建号、链接、版权）

**通用 Tab — 外观设置：**
- 外观模式 Picker：跟随系统 / 浅色模式 / 深色模式
- 通过 `@AppStorage("appearanceMode")` 持久化
- 切换时调用 `NSApp.appearance = NSAppearance(named:)` 立即生效

**通用 Tab — 语言设置：**
- 语言 Picker：列出所有支持的语言（en、zh-Hans）
- 通过 `LanguageManager.shared.current` 绑定
- 切换后大部分界面立即生效（通过 `.localized()` 修饰符）
- 下方显示提示文字说明切换行为

#### GlassCard（玻璃卡片）
- macOS 26+：使用 `.glassEffect()`（如可用）
- 低版本降级：`.background(.ultraThinMaterial)` 配合圆角和细边框

#### PointerCursor（小手光标）
- ViewModifier，鼠标悬浮时设置 `NSCursor.pointingHand`
- 应用于所有按钮、链接和可点击的列表行

#### 开发构建脚本（build-dev.sh）
- debug 配置构建到 `.dev-build/`
- 使用 dev bundle ID（`<bundle-id>.dev`）创建 .app
- 用 sips 将原始图标转为灰度图标以区分
- 开发版名称：`<应用名> Dev`
- 构建后自动杀掉旧实例并重新启动
- 使用 `codesign --force --deep --no-strict --sign -` 签名
- 资源 bundle 放在 .app 根目录（不是 Contents/Resources/），以适配 SPM Bundle.module

#### 发布脚本（release.sh）
- 接受版本号作为参数
- 分别为 arm64 和 x86_64 构建 release 版
- 创建包含正确 Info.plist（注入版本号）的 .app bundle
- 生成 DMG：`<应用名>-<version>-arm64.dmg` 和 `<应用名>-<version>-x86_64.dmg`
- 创建 GitHub tag 和 release，上传 DMG 作为 assets
- 资源 bundle 放置方式与 dev 构建一致

#### .gitignore
```
.build/
.dev-build/
.release/
.swiftpm/
*.xcodeproj
*.xcworkspace
DerivedData/
.DS_Store

# AI 工具
.claude/
.cursor/
.windsurf/
.copilot/
CLAUDE.md
```

#### 落地页（docs/index.html）
- 静态单页，放在 `docs/` 目录下
- 通过 GitHub Pages 部署（Settings → Pages → Source: Deploy from branch, Branch: main, Folder: /docs）
- 推送后自动部署，无需额外 CI
- 落地页采用现代极简风格，可使用 `/frontend-design` 技能生成高质量 UI

**国际化语言支持：**
- 至少支持：中文（zh）、英文（en）、日文（ja）、韩文（ko）、法文（fr）、德文（de）、西班牙文（es）
- 语言切换按钮放在顶部导航栏，使用下拉菜单或切换按钮
- 自动检测浏览器语言（`navigator.language`），默认匹配最近的语言
- 语言选择持久化到 `localStorage`
- 所有文案通过 JS 对象管理，切换时动态替换页面文本

**深色/浅色模式：**
- 默认跟随系统（`prefers-color-scheme`），自动切换
- 提供手动切换按钮（太阳/月亮图标），放在导航栏
- 用户手动选择后持久化到 `localStorage`，优先于系统偏好
- 使用 CSS 变量管理颜色主题，确保所有元素（背景、文字、卡片、代码块等）都适配

**页面内容结构：**
- Hero 区域：应用名称、标语、下载按钮
- 截图展示：轮播或网格
- 功能特性：网格卡片展示核心功能
- 赞助区域（独立 Section）：标题 + 说明文字 + 赞助方式（微信/支付宝收款码、PayPal 按钮等）
- 安装方式：Homebrew 命令 + 手动下载
- 技术栈 & 开源信息
- 页脚：版权、GitHub 链接

**顶部导航栏：**
- 应用名称/Logo
- 功能特性锚点链接
- Sponsor 链接（heart 图标 + 文字），醒目但不突兀
- 语言切换
- 深色/浅色切换
- GitHub 图标链接

#### 开源协议（LICENSE）
- **必须先询问用户**想使用哪种开源协议，不要默认选择
- 常见选项供参考：GPL-3.0、MIT、Apache-2.0、BSL、私有协议
- 根据用户选择生成对应的 LICENSE 文件

#### CLAUDE.md
生成标准的项目说明文件，包含：
- 构建与运行命令
- 架构概览
- 关键设计模式
- 防崩溃规则（禁止强制解包、NSView 生命周期注意事项）
- 兼容性要求
- 本地化使用说明

### 脚手架完成后

1. 初始化 git 仓库：`git init && git add -A && git commit -m "Initial project scaffold"`
2. 运行 `./scripts/build-dev.sh` 验证项目能正常构建和启动
3. 告知用户已创建的内容及后续步骤：
   - 替换 AppIcon.icns 为自己的图标（或使用 `/app-icon-generator` 生成）
   - 如需要可创建 GitHub 仓库
   - 在 Models/ 中添加 SwiftData 模型
   - 添加视图和业务逻辑
