---
name: root-cause
description: >
  First-principles analysis — force the AI to reason from fundamental facts
  instead of pattern-matching from training data. Use for debugging (find the
  real root cause, not the surface symptom), architecture decisions (is this
  the right approach, or just a familiar one?), and solution design (should we
  really solve it this way?).
  Use when user says: "root-cause", "根因分析", "第一性原理", "first principles",
  "从本质出发", "为什么会这样", "治本不治标", "这个问题的本质是什么",
  "不要套方案", "重新推导", "think from scratch", "why does this really happen",
  or when the user is unsatisfied with a surface-level fix.
---

# Root Cause — First-Principles Analysis

Force reasoning from fundamental facts. No analogies, no "this looks like X so do Y", no pattern-matching from similar codebases. Start from what is actually true and derive what should be done.

## When to Use

- **Debugging**: The surface fix is obvious, but you suspect a deeper issue
- **Architecture**: Deciding between approaches — is the familiar pattern actually right for this case?
- **Solution design**: Before adopting an existing pattern, verify it's the right one

## The Process

### Step 1: Strip Away Assumptions

List every assumption baked into the current approach or the proposed fix. For each one, ask: is this actually true in our specific context, or are we just carrying it over from convention?

Print each assumption as:

```
⚠️ Assumption: [what we're taking for granted]
   Evidence for: [does evidence support this?]
   Evidence against: [anything contradicting it?]
   Verdict: ✅ Holds / ❌ Doesn't hold / ❓ Unverified
```

### Step 2: Identify Fundamental Facts

List only what is provably true — from the code, the data, the logs, the runtime behavior. No "usually", no "typically", no "in most projects".

```
📌 Fact 1: [concrete observation with file:line or log evidence]
📌 Fact 2: [concrete observation with file:line or log evidence]
...
```

### Step 3: Derive the Answer from Facts

From the facts alone, reason forward:
- For bugs: what is the actual causal chain from trigger to symptom?
- For architecture: what does the data flow / responsibility boundary / actual constraint demand?
- For design: what solution follows from the real requirements, not from "how we did it last time"?

### Step 4: Compare with the Obvious Answer

Now compare your first-principles derivation with whatever the "obvious" or "conventional" answer was:

```
🔍 Conventional approach: [what pattern-matching would suggest]
🔍 First-principles answer: [what the facts demand]
🔍 Delta: [where they differ and why it matters]
```

If they agree — great, the conventional approach is validated. If they diverge — the delta is where the real insight lives.

### Step 5: Recommend

State the recommendation clearly. If it differs from the obvious approach, explain why the first-principles answer is better with specific evidence, not just "it's more correct".

## Hard Rules

1. **No "usually" / "typically" / "in most cases"** — these are analogies in disguise. State what is true HERE.
2. **No solution before diagnosis** — if this is a bug, you must trace the actual causal chain before proposing a fix.
3. **Challenge your own answer** — after deriving the answer, spend 30 seconds trying to break it. If you find a flaw, iterate.
4. **Cite evidence** — every claim must reference a file:line, a log entry, a data point, or a reproducible observation. "I believe" is not evidence.

## Examples of First-Principles Thinking

| Surface answer | First-principles question | What you might find |
|---|---|---|
| "The API is slow, add a cache" | Why is it slow? What's the actual bottleneck? | The N+1 query is the real problem; a cache just hides it |
| "Add a retry for this flaky test" | Why does it flake? What's the timing dependency? | A race condition in setup that retry can't fix |
| "Use the same pattern as module X" | Does this module have the same constraints as X? | X was designed for batch processing; this is real-time — different pattern needed |
| "The config was changed, revert it" | Why was the config changed? What was the original intent? | The config change exposed a deeper routing issue that existed for months |
