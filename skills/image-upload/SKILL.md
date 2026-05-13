---
name: image-upload
description: >
  Upload images to your own GitHub repo and get jsDelivr CDN, GitHub raw, and
  Markdown URLs back. Supports file paths (single or batch in parallel) and
  clipboard (screenshots from Cmd+Shift+4, or files copied from Finder).
  Use when the user says: "upload image", "image upload", "image hosting",
  "screenshot upload", "upload to github", "paste this image", "host this image",
  "上传图片", "图床", "把截图传上去", "把这张图传到 github".
---

# image-upload

Upload any image to your own GitHub repo and get back three URL formats — jsDelivr CDN (fast, public), GitHub raw, and Markdown — ready to paste into documentation, blog posts, or chats.

## Prerequisites (one-time setup)

1. **A GitHub repo for images.** Create one yourself (public preferred so jsDelivr CDN serves it), e.g. `your-username/images`.
2. **`gh` CLI installed and authenticated:**
   ```bash
   brew install gh
   gh auth login
   ```
3. **`jq` installed** (for JSON serialization):
   ```bash
   brew install jq
   ```
4. **`pngpaste` (only for clipboard screenshot mode):**
   ```bash
   brew install pngpaste
   ```
5. **Set environment variables** in your shell profile (`~/.zshrc` or `~/.bashrc`):
   ```bash
   export IMAGE_HOST_REPO="your-username/images"   # required
   export IMAGE_HOST_BRANCH="master"               # optional, default: master
   export IMAGE_HOST_BASE_DIR="uploads"            # optional, default: uploads
   ```
   Reload your shell or `source ~/.zshrc`.

Per-invocation overrides via `--repo`, `--branch`, `--base-dir` flags also work.

## Usage

Upload one or more files:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/upload_image.sh" path/to/image.png
bash "${CLAUDE_SKILL_DIR}/scripts/upload_image.sh" file1.jpg file2.png file3.webp
```

Upload from clipboard (most recent screenshot, or files copied in Finder):

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/upload_image.sh" --clipboard
```

Auto-copy a specific URL format to system clipboard:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/upload_image.sh" --copy markdown file.png
bash "${CLAUDE_SKILL_DIR}/scripts/upload_image.sh" --copy jsdelivr --clipboard
bash "${CLAUDE_SKILL_DIR}/scripts/upload_image.sh" --copy raw file1.jpg file2.jpg
```

`--copy` values: `jsdelivr` (CDN), `raw` (GitHub raw), `markdown` (`![](url)` format).

## How it works

- Files are renamed to timestamp format: `20260513-143025.jpg`. Batch uploads add an index: `-1`, `-2`, etc.
- Each image is committed to `<base-dir>/YYYY/MM/<name>.<ext>` in your repo.
- Filename conflicts auto-resolve with a numeric suffix.
- Multiple files upload in parallel (with retry on transient 409s from branch HEAD races).
- For each image, three URLs are printed: jsDelivr CDN, GitHub raw, and Markdown.

## Calling from Claude Code

The Bash tool does NOT support interactive input, so when invoked through Claude:

1. Run the upload **without** `--copy` to get the URLs in stdout.
2. Use `AskUserQuestion` to ask which format the user wants to copy. Options:
   - jsDelivr CDN URL
   - GitHub Raw URL
   - Markdown format
   - Don't copy
3. Based on the answer, use `echo -n "<url>" | pbcopy` to copy that exact format.

When the user runs the script directly in their terminal (not through Claude), the script has its own built-in interactive prompt.

## Failure modes

- `IMAGE_HOST_REPO` not set → script exits with code 2 and prints setup instructions
- `gh` not authenticated → script exits with code 2 and tells user to run `gh auth login`
- `jq` / `pngpaste` missing → script exits with helpful install hint
- Upload fails after 3 retries → script reports the specific file that failed; other parallel uploads continue
