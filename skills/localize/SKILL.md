---
name: localize
description: >
  Batch update multi-language localization files in parallel.
  Use when user says: "更新多语言", "本地化更新", "翻译到所有语言",
  "update all languages", "localize", "多语言同步",
  or asks to apply a change across multiple language files.
---

# Localize — 多语言批量更新

将一个内容变更同步到项目中所有语言文件，使用并行 Agent 加速。

## Workflow

### 1. 识别语言文件

扫描项目，找到所有语言/本地化文件（常见模式）：
- `locales/*.json` / `locales/*.yml`
- `i18n/*.ts` / `i18n/*.js`
- `lang/*.php`
- `*.lproj/*.strings`（macOS/iOS）
- 或用户指定的路径

列出找到的所有语言文件，请用户确认。

### 2. 理解变更内容

读取基准语言文件（通常是中文或英文），理解本次要变更的内容：
- 新增的 key 和文案
- 修改的文案
- 删除的 key

向用户展示变更摘要，确认后继续。

### 3. 并行更新所有语言

为每个语言文件启动一个 Agent，并行执行：
- 保留该语言文件的现有结构和未变更的翻译
- 对变更内容进行翻译（新增/修改的文案）
- 删除已移除的 key
- 新增内容如果无法准确翻译，使用基准语言文案作为 fallback 并加注释标记

**重要**：每个 Agent 必须验证文件原有结构完整保留，不能丢失任何未变更的内容。

### 4. 汇总与确认

所有 Agent 完成后：
1. 展示变更汇总表（每种语言的改动数量）
2. 如果项目有 lint/build 命令，运行检查
3. 等用户确认后再提交

### 注意事项

- 不要假设语言文件的格式，先读取确认实际格式
- 保持各语言文件的排序方式与原文件一致
- 如果某个语言文件格式与其他不同，单独处理而不是套用模板
