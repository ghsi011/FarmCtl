# Project Brief

## Project Title
Minimal CLI‑Driven Android Starter (API 34+, Kotlin)

## Objective
Provide a well‑documented, command‑line–friendly Android project template that:
1. Targets Android 14 (API level 34) or higher.
2. Uses Kotlin as the primary language and Kotlin‑DSL Gradle scripts.
3. Integrates modern Jetpack libraries (Compose for UI, Room for persistence, Hilt for DI).
4. Supports complete lifecycle via terminal: build, test (unit + UI), package, and deploy to a connected device.
5. Centralises dependency versions with Gradle Version Catalogs.
6. Includes automated CI using GitHub Actions (build & test on every push / PR).
7. Maintains an in‑repo Memory Bank for AI/human context continuity.

## Why This Matters
• Developers and AI assistants benefit from a minimal, reproducible setup that avoids heavy IDE requirements.
• Modern Android best‑practices (Compose, Hilt, Room, Material3) are included out of the box.
• Automated CI ensures the template remains green as dependencies evolve.
• The Memory Bank pattern preserves architectural decisions across stateless AI sessions.

## Deliverables
1. `guidlines.md` – step‑by‑step setup guide (already present).
2. `memory-bank/` documentation set (this file + complementary context files).
3. Sample GitHub Actions workflow (`.github/workflows/ci.yml`).
4. Ready‑to‑run Gradle project structure.

## Core Requirements
| Area | Requirement |
| ---- | ----------- |
| SDK | Compile/target SDK 34, min SDK ≥21 |
| Build | Kotlin DSL with AGP ≥8, JDK 17 |
| Libraries | Compose, Material3, Room, Hilt, AndroidX core & lifecycle |
| Testing | JUnit4, MockK, Espresso, Hilt test rule |
| CI | Ubuntu‑based workflow: checkout → JDK → cache → SDK → build → test → artifacts |
| Documentation | Memory Bank files kept up‑to‑date after significant changes |

## Out‑of‑Scope (for now)
• Release signing / Play Store deployment.
• Multi‑module architecture.
• Advanced build variants.

---
_This file is the foundation for all other Memory Bank documents. Keep it updated whenever project scope, goals, or core requirements change._ 