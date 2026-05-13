# mac-cleanup-memory 设计文档

## 背景

`mac-cleanup-process` 找的是**异常**进程（应该死的没死）；`mac-cleanup-disk` 清的是磁盘。但日常 macOS 卡顿最常见的诉求其实是第三类——"我没死什么进程，但内存紧张，谁在占？"。

这就是这个 skill 要补的位：从**内存视角**看系统，列大户，不评价、由用户决定关谁。

## 核心目标

1. **零评价**：不输出"建议杀谁"。报告只列事实，决定权完全在用户手里
2. **按 app 聚合**：单个 PID 看微信只占 600 MB，看不到全貌；聚合后能看到 WeChat 全家桶 2 GB
3. **客观观察**：用规则识别可疑模式（多个同名进程、swap 接近上限等），但只描述不建议
4. **kill 时极度小心**：用户明示 PID 才动手，且走完整的 7 步安全协议，绝不批量模式匹配

## 三件套定位

| skill | 视角 | 典型问题 |
|-------|------|---------|
| `mac-cleanup-process` | 异常进程 | "MCP server 孤儿一堆没退" |
| `mac-cleanup-memory` | 内存全景 | "内存满了，谁占的？" |
| `mac-cleanup-disk` | 磁盘空间 | "磁盘满了，清缓存" |

## 关键设计决策

### 决策 1：不主动建议 kill 谁

**选项 A**：像 mac-cleanup-process 一样，给"建议命令块"列出可疑 PID 让用户复制粘贴
**选项 B**（采用）：纯数据展示，由用户口头说"kill 哪个"，Claude 走严格协议

**原因**：
- process skill 找的是"明确异常"的进程（孤儿、卡死），列建议合理
- memory skill 看的是**正常**进程的占用，"哪些该关"是主观决策
- 列建议会诱导用户误杀（看见"3 个 claude"建议就全杀，但其中一个可能正在跑长任务）

### 决策 2：按 app 聚合而不是按可执行 basename 聚合

**坑**：直接按命令第一个 token 的 basename 聚合，会把 "Google Chrome --restart" 拆成 "Google"，"Visual Studio Code" 拆成 "Visual"。

**正确做法**：先看路径里有没有 `*.app/`，有就用最外层 .app 的名字（去 `.app` 后缀）；没有再 fallback 到 basename。

```awk
function get_app(cmd) {
  pos = index(cmd, ".app/")
  if (pos == 0) {
    # fallback: basename of first token
    n = split(cmd, parts, " ")
    first = parts[1]
    m = split(first, segs, "/")
    return segs[m]
  }
  before = substr(cmd, 1, pos - 1)
  for (i = length(before); i >= 1; i--) {
    if (substr(before, i, 1) == "/") return substr(before, i + 1)
  }
  return before
}
```

这样 `/Applications/WeChat.app/.../wxocr` 和 `/Applications/WeChat.app/.../WeChat` 都归到 "WeChat" 组。

### 决策 3：duplicate observation 加 count 上限

**坑**：报告"33 个 node"、"26 个 Google Chrome"完全是噪音——Electron/Chromium 架构注定有大量 helper，用户没法"少开几个"。

**规则**：只报告 `count >= 2 && count <= 8 && total_rss >= 500MB` 的 app。

- count 2-8：跨多个独立实例（多个 claude 会话、多个 VSCode 窗口）的常见区间
- count > 8：基本是 helper 大军，架构性的，不可减少
- total RSS >= 500MB：低于这个值不值得提

### 决策 4：page size 必须自适应

```bash
PAGE_SIZE_BYTES="$(sysctl -n hw.pagesize)"
```

Apple Silicon 是 16384 bytes (16K)，Intel Mac 是 4096 bytes (4K)。硬编码 4K 在 M 系列机器上**算出来全错**（差 4 倍）。

通用原则：列表/常量类的东西默认按"运行时取"处理，不要硬编码。Apple Silicon vs Intel page size 就是典型——硬编码 4K 在 M 系列机器上**算出来全错**。

### 决策 5：压力等级用简化阈值表

`memory_pressure` 命令的真实判定涉及：free %、compressor 速率、swap 活动、kernel notification level。完整模拟太复杂。

简化用 free percentage 单一指标：

| Free % | 等级 |
|--------|------|
| > 70% | Normal (健康) |
| 40-70% | Normal (有压力) |
| 10-40% | Warning |
| < 10% | Critical |

不完全准确（macOS 在 free 30% 但 swap 已满时会触发 Warning），但作为粗略对照够用。文档里说明这是简化模型。

### 决策 6：kill 协议的"防误伤"7 条规则

来源：用户明确要求"杀进程时要仔细再仔细，别杀错"。

每条规则对应一个真实的失败模式：

| 规则 | 防的失败模式 | 真实案例 |
|------|------------|---------|
| 1. 黑名单硬拒 | 用户失手指定 PID 1 / WindowServer | `kill 1` 直接 panic |
| 2. PID 重用校验 | 扫描后 PID 已被回收给系统进程 | macOS PID 复用很快，30 秒 idle 后就可能 |
| 3. 系统 UI 二次确认 | 杀 Finder/Dock 不致命但用户不一定知道 | 误杀 ControlCenter 会让顶栏短暂消失 |
| 4. SIGTERM 优先 | SIGKILL 让 app 来不及保存 | VSCode/微信都有未保存内容 |
| 5. 批量逐条 echo | 用户口误说错 PID | "5"和"6"输错一个数字就杀错 |
| 6. 永不 pkill -f | 模式匹配会误伤 | `pkill -f Chrome` 会匹到 ChromeDriver、任何路径含 Chrome 的进程 |
| 7. audit log | 出问题能追溯 | 如果用户事后说"系统怎么变怪了"能查 |

每条都不是过度防御——都对应过去会发生的真实事故。

## 输出格式选择

Markdown 表格 + 分节，原因：
- Claude 直接呈现给用户，对话框渲染表格 OK
- 落盘到 `~/Downloads` 也直接能 Preview / Typora / Obsidian 打开
- 不依赖任何额外 renderer

## 性能特征

实测在 32 GB / 200+ 进程的 Mac 上：
- vm_stat: < 50ms
- ps 全量: < 200ms
- awk 聚合: < 100ms
- 总体 < 1 秒

不需要缓存或异步。

## 未来可能的扩展

不在 v1.0 范围，但留着思考：

1. **历史趋势**：每次跑 scan 把关键指标写入 `<skill-dir>/history.csv`，能看到一周内压力变化
2. **App 白名单（"重要 app 不要建议关"）**：如果决策 1 改了要支持建议，可以加个白名单
3. **集成 Activity Monitor energy impact**：高能耗 != 高内存，但用户语义上可能混着问
4. **Webhook on Critical**：自动在压力进入 Critical 时通知

## 维护注意

- `scan.sh` 是脚本核心，改逻辑改这里
- `SKILL.md` 是 Claude 的行为指引，改交互流程改这里
- 改 kill 协议**一定要同步更新**：SKILL.md / README.md / 本文件三处都讲了 7 条规则
- 添加新观察类型时：scan.sh 里 `render_observations` 加 case，README.md 报告内容章节加描述
