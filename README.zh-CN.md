# agent-ssot

**跨 macOS / Linux / Windows 平台与主流 AI Coding Agent 的全局配置单一事实来源（SSOT）。**

[English](./README.md) | [简体中文](./README.zh-CN.md)

`agent-ssot` 将全局工程约束（`AGENTS.md`）与跨工具复用技能（`skills/`）统一沉淀在 `~/.agents/` 目录下，并通过无损条目级映射分发给主流 CLI 与 IDE 形态的 AI Agent，同时完整保留各工具自带或自动生成的私有技能。

---

## 核心设计原则

1. **渐进式代码检索（`Graph -> Paths -> Slices`）：** 优先使用 `codegraph` / LSP 符号图谱查询调用链，其次使用带输出上限的 Rust CLI 工具（`rg`、`fd`、`ast-grep`、`eza`、`dust`、`difft`），减少全量文件倾倒带来的上下文膨胀。
2. **输出压缩友好：** 规范原子化、低噪音的终端命令执行方式，与 `rtk` 等输出压缩器配合降低单轮 Token 消耗。
3. **保守的条目级分发：** 保留已有技能目录及非本项目链接（包括悬空链接）；遇到冲突时跳过，已有普通指令文件在替换前备份。
4. **编排器中性：** 不在公共规范中硬编码单一厂商的私有工具原语或调度逻辑，避免与 `OmO`、`omp`、`agy`、Claude Code、Codex CLI 的原生编排机制冲突。

---

## 快速开始

### macOS / Linux
```bash
git clone https://github.com/arrislink/agent-ssot.git
cd agent-ssot
chmod +x scripts/sync-agents.sh
./scripts/sync-agents.sh --dry-run
./scripts/sync-agents.sh
```

### Windows (PowerShell)
```powershell
git clone https://github.com/arrislink/agent-ssot.git
cd agent-ssot
.\scripts\sync-agents.ps1 -DryRun
.\scripts\sync-agents.ps1
```

如果技能目录本身是符号链接，脚本会保留并跳过它；请检查 `[SKIP]` 输出。Windows 无法创建 junction 时会创建受管理副本，后续同步会更新源文件，但不会自动删除源中已移除的文件。指令文件复制回退后，每次更新会先备份旧副本。

各工具对规则及技能路径的实际发现行为可能随版本变化，尚未对所有产品逐一验证。隔离测试：macOS/Linux 执行 `bash tests/test-sync-agents.sh`，Windows 执行 `pwsh -File tests/test-sync-agents.ps1`。

2026-11-19 验证记录：在 macOS 上执行 `/bin/bash -n scripts/sync-agents.sh` 和 `/bin/bash tests/test-sync-agents.sh` 均通过。本机没有 `pwsh`，PowerShell 测试未运行；已添加 CI 工作流，但尚未验证其运行结果。
