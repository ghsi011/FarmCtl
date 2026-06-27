# Coach History — FarmCtl

**Last coach run**: 2026-06-27 (score 7/10)
**Last deep CLAUDE.md optimization**: never

## 2026-06-27 — First coach run (score 7/10)

Accepted & implemented:
- **#1 CLAUDE.md** — Created root `CLAUDE.md` importing `@AGENTS.md` plus Claude-Code-specific notes. Reason: `AGENTS.md` was not being loaded into Claude Code's context (only the global CLAUDE.md was), so the project guide, build commands, and conventions were invisible.
- **#4 Memory** — Created project memory `farmctl-architecture.md` + `MEMORY.md` index (Gist-backed telemetry, background alarm watchdog, multi-platform Flutter stack).
- **#3 Dart/Flutter LSP** — Installed `dart-lsp` as a skills-directory plugin (`~/.claude/skills/dart-lsp/` with `.claude-plugin/plugin.json` + `.lsp.json`) pointing at the real `dart.exe`. Auto-loads as `dart-lsp@skills-dir` on next restart. User-global, but only activates on `.dart` files. Requires a Claude Code restart to take effect.

Noted, not actioned:
- **#2 Disk** — `parametric-3d-printing` user skill is 919.7 MB (~99% of `~/.claude/skills`). Informational only; outside coach's project write-scope.

Out of scope this run:
- Global `~/.claude/settings.json` not audited (user declined the read; also outside coach's write-scope by design).
