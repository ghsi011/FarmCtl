# Product Context

## Problem Statement
Setting up a modern Android project from scratch is time‑consuming and error‑prone, especially when you want to:
* Use Jetpack Compose, Room, Hilt, and Material3 cohesively.
* Drive the entire workflow via terminal/CI without Android Studio UI.
* Keep dependencies/versions in sync.
* Retain architectural knowledge across stateless AI sessions.

## Target Users
• Solo developers & small teams who prefer lightweight tooling.
• DevOps/CI pipelines needing reproducible Android builds.
• AI coding assistants that must bootstrap Android code without IDE assistance.

## How This Template Solves the Problem
1. Provides a pre‑configured Gradle + Kotlin project targeting API 34.
2. Centralises dependency versions for easy upgrades.
3. Supplies tested sample workflow for GitHub Actions.
4. Embeds Memory Bank docs for knowledge persistence.

## User Experience Goals
| Goal | Description |
| ---- | ----------- |
| Fast Onboarding | Clone → `./gradlew build` should succeed with minimal setup. |
| IDE‑Agnostic | All essential tasks callable from CLI, yet IDEs remain compatible. |
| Reliability | CI validates every commit; template should stay green. |
| Clarity | Inline comments and markdown explain configuration choices. |

---
_Update this file when product vision or user personas evolve._ 