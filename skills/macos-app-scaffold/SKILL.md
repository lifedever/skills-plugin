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

# Create a macOS App Project

Generates a production-grade native macOS app scaffold based on best practices distilled from shipped projects like [TaskTick](https://github.com/lifedever/TaskTick).

## Pre-flight Checks

Verify the development environment before starting. Stop and guide the user to install anything that's missing:

```bash
xcodebuild -version 2>/dev/null | head -1
swift --version 2>/dev/null | head -1
```

- **Xcode >= 16** (i.e. `xcodebuild -version` reports `Xcode 16.x` or higher). The scaffold uses `swift-tools-version: 6.0`; Xcode 15 will fail SPM resolution. Xcode 15 users should upgrade, or confirm they're OK downgrading the generated project to Swift 5.9.
- **Swift >= 6.0** (same reason as above)
- Generation location defaults to the user's home directory. Confirm with the user first if they want a different location.

## Usage

```
/macos-app-scaffold <AppName> [--bundle-id com.example.app] [--github user/repo]
```

- `AppName`: required, PascalCase (e.g. `MyApp`)
- `--bundle-id`: optional, defaults to `com.example.<AppName>` (please change to your own reverse domain on first use)
- `--github`: optional, GitHub repo used for auto-update, format `<owner>/<repo>`

## Generated Output

Generates the project structure below. Ask the user for the creation location first (default: `~/<AppName>-app/`).

### Project Structure

```
<AppName>-app/
├── Package.swift
├── Sources/
│   ├── App/
│   │   ├── <AppName>App.swift          # @main, multi-window Scene, ModelContainer
│   │   ├── AppDelegate.swift           # Cmd+Q → hide to menu bar, shouldReallyQuit
│   │   └── Localization.swift          # L10n.tr() helper + LanguageManager
│   ├── Engine/
│   │   ├── UpdateChecker.swift         # GitHub Releases API, DMG download/install/restart
│   │   └── NotificationManager.swift
│   ├── Models/
│   │   └── (empty directory, user adds SwiftData models here)
│   ├── Views/
│   │   ├── Main/
│   │   │   └── MainWindowView.swift    # NavigationSplitView layout
│   │   ├── MenuBar/
│   │   │   └── MenuBarView.swift       # MenuBarExtra popover content
│   │   ├── Settings/
│   │   │   └── SettingsView.swift      # TabView: General, Updates, About
│   │   └── Components/
│   │       ├── GlassCard.swift         # macOS 26 liquid glass + fallback
│   │       └── PointerCursor.swift     # .pointerCursor() pointing-hand modifier
│   ├── Localization/
│   │   ├── en.lproj/
│   │   │   └── Localizable.strings
│   │   └── zh-Hans.lproj/
│   │       └── Localizable.strings
│   └── Resources/
│       └── AppIcon.icns                # placeholder icon, user replaces
├── Tests/
│   └── <AppName>Tests.swift
├── scripts/
│   ├── build-dev.sh                    # dev build: grayscale icon, separate bundle ID
│   └── release.sh                      # release: arm64 + x86_64 DMG, upload to GitHub Release
├── docs/
│   └── index.html                      # static landing page, auto-deployed via GitHub Pages
├── .gitignore
├── LICENSE                             # ask user which open-source license to use
├── CLAUDE.md                           # Claude Code project documentation
└── .claude/
    └── skills/
        └── release/
            └── SKILL.md                # /release <version> release skill
```

### Implementation Rules

Strictly follow these rules when generating code:

#### Package.swift
- swift-tools-version: 6.0
- `defaultLocalization: "en"`
- `platforms: [.macOS(.v14)]`
- Resources: `.process("Localization")`

#### App Entry Point (<AppName>App.swift)
- Multi-window: `Window` (main window) + `MenuBarExtra` + `Settings` + editor windows, etc.
- `ModelContainer` database isolation: dev bundle ID → `<appname>-dev.store`, release → `default.store`
- Complete `.commands {}` menu structure:
  - After appInfo: About, Check for Updates, Support the Developer (heart icon)
  - newItem: app-specific actions
  - After toolbar: Refresh
  - help: GitHub homepage, Report Issue

#### AppDelegate
- `shouldReallyQuit` static flag
- `applicationShouldTerminate`: if shouldReallyQuit is false → close windows, hide to menu bar, return `.terminateCancel`
- Only the menu bar's "Quit" button sets `shouldReallyQuit = true`

#### UpdateChecker (auto-update)
- Polls GitHub Releases API: `https://api.github.com/repos/<owner>/<repo>/releases/latest`
- Compares semver versions, shows UpdateDialogView: Skip This Version / Remind Me Later / Install Now
- Download DMG → mount → copy .app to /Applications → unmount → relaunch via `open`
- Dev builds (bundle ID ending in `.dev`) skip update checks
- Configurable check interval (defaults to 24 hours)

#### Localization
- `L10n.tr("key")` and `L10n.tr("key", arg)` helpers
- `LanguageManager` singleton, uses `@AppStorage("appLanguage")`
- `.localized()` view modifier, triggers re-render on language change
- Bundle.module case-insensitive `.lproj` folder lookup
- Two languages: en, zh-Hans. Every string must be present in both files.

#### SettingsView (settings window)
- `TabView` with each tab using `Form { ... }.formStyle(.grouped)`
- `.frame(width: 460).fixedSize(horizontal: false, vertical: true)` for fixed width and adaptive height
- Tabs: General (appearance, language, launch at login), Updates (auto-check, frequency, check now), About (version, build, links, copyright)

**General Tab — Appearance:**
- Appearance mode picker: Follow System / Light / Dark
- Persisted via `@AppStorage("appearanceMode")`
- Calls `NSApp.appearance = NSAppearance(named:)` on change for instant effect

**General Tab — Language:**
- Language picker: lists all supported languages (en, zh-Hans)
- Bound to `LanguageManager.shared.current`
- Most UI updates immediately after switching (via `.localized()` modifier)
- Help text below explains the switching behavior

#### GlassCard
- macOS 26+: uses `.glassEffect()` (when available)
- Fallback for older versions: `.background(.ultraThinMaterial)` with rounded corners and thin border

#### PointerCursor
- ViewModifier that sets `NSCursor.pointingHand` on hover
- Applied to all buttons, links, and clickable list rows

#### Dev Build Script (build-dev.sh)
- Builds debug config to `.dev-build/`
- Creates .app with dev bundle ID (`<bundle-id>.dev`)
- Uses sips to convert original icon to grayscale for visual distinction
- Dev app name: `<AppName> Dev`
- Kills any old instance and relaunches after build
- Signs with `codesign --force --deep --no-strict --sign -`
- Resource bundles placed at .app root (not Contents/Resources/) to match SPM Bundle.module

#### Release Script (release.sh)
- Accepts version number as argument
- Builds release configs for arm64 and x86_64 separately
- Creates .app bundle with proper Info.plist (version injected)
- Produces DMGs: `<AppName>-<version>-arm64.dmg` and `<AppName>-<version>-x86_64.dmg`
- Creates GitHub tag + release, uploads DMGs as assets
- Resource bundle layout matches the dev build

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

# AI tools
.claude/
.cursor/
.windsurf/
.copilot/
CLAUDE.md
```

#### Landing Page (docs/index.html)
- Static single-page, placed in `docs/`
- Deployed via GitHub Pages (Settings → Pages → Source: Deploy from branch, Branch: main, Folder: /docs)
- Auto-deploys on push, no extra CI needed
- Modern minimalist style; you can use the `/frontend-design` skill to generate high-quality UI

**i18n language support:**
- Minimum coverage: Chinese (zh), English (en), Japanese (ja), Korean (ko), French (fr), German (de), Spanish (es)
- Language switcher in the top nav bar, using a dropdown or toggle button
- Auto-detect browser language (`navigator.language`), default to the closest match
- Persist language choice to `localStorage`
- All copy managed via a JS object, swap page text dynamically on switch

**Dark / Light mode:**
- Default follows system (`prefers-color-scheme`), switches automatically
- Manual toggle button (sun/moon icon) in the nav bar
- User's manual selection persisted to `localStorage`, takes precedence over system preference
- Use CSS variables for color themes so every element (backgrounds, text, cards, code blocks, etc.) adapts

**Page content structure:**
- Hero section: app name, tagline, download button
- Screenshots: carousel or grid
- Features: grid of cards highlighting core features
- Sponsor section (standalone): heading + description + sponsorship methods (WeChat/Alipay QR codes, PayPal button, etc.)
- Install methods: Homebrew command + manual download
- Tech stack & open-source info
- Footer: copyright, GitHub link

**Top nav bar:**
- App name / logo
- Anchor links to feature sections
- Sponsor link (heart icon + text), prominent but not intrusive
- Language switcher
- Dark / light toggle
- GitHub icon link

#### LICENSE
- **You MUST ask the user first** which open-source license they want — do not pick a default
- Common options for reference: GPL-3.0, MIT, Apache-2.0, BSL, proprietary
- Generate the appropriate LICENSE file based on the user's choice

#### CLAUDE.md
Generate a standard project documentation file that includes:
- Build and run commands
- Architecture overview
- Key design patterns
- Anti-crash rules (no force-unwrap, NSView lifecycle gotchas)
- Compatibility requirements
- Localization usage notes

### After Scaffolding

1. Initialize git: `git init && git add -A && git commit -m "Initial project scaffold"`
2. Run `./scripts/build-dev.sh` to verify the project builds and launches
3. Tell the user what was created and the next steps:
   - Replace AppIcon.icns with your own icon (or use `/app-icon-generator` to generate one)
   - Create a GitHub repo if needed
   - Add SwiftData models under Models/
   - Add views and business logic
