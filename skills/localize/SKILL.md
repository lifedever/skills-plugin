---
name: localize
description: >
  Batch update multi-language localization files in parallel.
  Use when user says: "更新多语言", "本地化更新", "翻译到所有语言",
  "update all languages", "localize", "多语言同步",
  or asks to apply a change across multiple language files.
---

# Localize — Batch Multi-Language Update

Propagate a single content change across every language file in the project, using parallel agents to speed things up.

## Workflow

### 1. Identify Language Files

Scan the project for localization files. Common patterns:
- `locales/*.json` / `locales/*.yml`
- `i18n/*.ts` / `i18n/*.js`
- `lang/*.php`
- `*.lproj/*.strings` (macOS / iOS)
- Or a path the user specifies

List every language file found and ask the user to confirm.

### 2. Understand the Change

Read the baseline language file (usually Chinese or English) to understand the change:
- Added keys and copy
- Modified copy
- Removed keys

Show the user a change summary and continue after confirmation.

### 3. Update All Languages in Parallel

Spawn one agent per language file, running concurrently. Each agent must:
- Preserve the existing structure and unchanged translations of that language file
- Translate the changed content (new / modified copy)
- Remove the deleted keys
- For new content that can't be translated accurately, fall back to the baseline copy with a comment marker

**Important**: each agent must verify that the file's original structure is fully preserved — no unchanged content can be lost.

### 4. Recap and Confirm

After every agent finishes:
1. Show a change summary table (number of edits per language)
2. If the project has lint / build commands, run them
3. Wait for user confirmation before committing

### Notes

- Don't assume the language file format — read it first to confirm
- Preserve each file's original key ordering
- If one language file's format differs from the others, handle it individually rather than templating across the board
