# AGENTS: Working on FarmCtl

This document guides Codex agents contributing to FarmCtl. It defines project layout, coding conventions, and how to run, test, and extend the app so changes remain consistent and easy to review.

## Scope
- Applies to the entire repository unless a more deeply nested `AGENTS.md` overrides it.
- Direct user instructions always take precedence over this file.

## Repository Layout
- `app/` — Flutter application workspace
  - `lib/` — source, organized feature‑first
    - `core/router/` — app navigation via GoRouter (`app/lib/core/router/app_router.dart`)
    - `features/<feature>/view/` — top‑level pages/screens
    - `features/<feature>/widgets/` — reusable UI components for the feature
    - Suggested (use when needed): `features/<feature>/providers/`, `features/<feature>/models/`, `features/<feature>/data/`
  - `test/` — Flutter tests (widget/unit)
- `Spec.md` — product and UX specification
- `README.md` — quickstart and high‑level overview
- `tool/` — helper scripts for managing a repo‑local Flutter SDK
- `.agent/` — ExecPlans and temporary research (gitignored subdirectories for scratch work)

## 🗂️ ExecPlans

When writing **complex features** or **significant refactors**, use an **ExecPlan**
(as described in `.agent/PLANS.md`) from **design to implementation**.

ALWAYS check to see if an active ExecPlan is present and read it!!! 

Write new plans to the `.agent` directory.
Place any temporary research, clones, etc., in a **.gitignored subdirectory** of `.agent`.

## Tooling & Setup
- Flutter channel: stable (see `app/.metadata`).
- Dart SDK: constrained in `app/pubspec.yaml` (currently `'>=3.8.0 <4.0.0'`). Use a Flutter SDK that ships a compatible Dart version.
- Two setup paths:
  1) System‑wide Flutter install; or
  2) Repository‑managed SDK (Linux/macOS shells):
     - `./tool/setup_flutter.sh`
     - `source ./tool/flutter_env.sh`
     - Then `flutter doctor`
- On Windows, prefer a global Flutter install or WSL/Git Bash to run the helper scripts.

## Common Commands
- Install deps: `cd app && flutter pub get`
- Run app: `flutter run` (from `app/`)
- Run tests: `flutter test` (from `app/`)
- Lint/analyze: `flutter analyze` (from `app/`)
- Format: `dart format .` (run at repo root or within `app/`)
- Codegen (when using Freezed/Drift): `dart run build_runner build --delete-conflicting-outputs`

## Coding Conventions
- Follow `flutter_lints` plus project rules in `app/analysis_options.yaml` (notably `prefer_single_quotes: true`).
- Dart file names use `snake_case.dart`; types and widgets use `UpperCamelCase`.
- Keep diffs minimal and focused; avoid broad refactors unless requested.
- Don’t add license headers. Don’t introduce one‑letter identifiers.
- Favor immutable data, pure functions, and small widgets.
- Use `Theme.of(context)` and `ColorScheme` for colors/typography; keep Material 3 consistency.

## Architecture
- Organization is feature‑first. New UI should live under `app/lib/features/<feature>/…`.
- State management: Riverpod. Prefer providers over global singletons. Co‑locate feature providers under `features/<feature>/providers/`.
- Navigation: GoRouter, configured in `app/lib/core/router/app_router.dart` using a `StatefulShellRoute` with a bottom `NavigationBar`.
  - Add a new screen within an existing tab: create a `GoRoute` under the appropriate `StatefulShellBranch`.
  - Add a new top‑level tab: add a new `StatefulShellBranch` with a `GoRoute` and update `NavigationBar.destinations` and any associated labels/icons.
- Data layer (planned/gradual):
  - HTTP via Dio: wrap calls behind repositories/services co‑located in the feature’s `data/` folder.
  - Local persistence via Drift (when introduced). Keep schema and DAOs in a `data/` or `db/` subfolder.
  - Models via Freezed: place in `models/`, generate code with build_runner.

## Adding Features (Checklist)
1) Create screen under `features/<feature>/view/` and supporting widgets under `features/<feature>/widgets/`.
2) Add or update providers in `features/<feature>/providers/` as needed.
3) Wire up navigation in `core/router/app_router.dart`.
4) Write or update tests in `app/test/`.
5) Run format, analyze, and tests before finishing.
6) Update or create an ExecPlan under `.agent/` as architecture/scope evolves; update `Spec.md` if behavior/UX changes.

## Testing Guidelines
- Prefer widget tests for UI contracts and navigation, co‑located under `app/test/`.
- Keep tests deterministic; avoid real network or time dependencies.
- Name tests descriptively and assert visible user outcomes (e.g., tab labels, routed content), similar to `app/test/widget_test.dart`.

## Dependencies
- Keep the dependency set lean. Before adding a new package to `pubspec.yaml`, ensure it’s justifiable and aligns with the relevant ExecPlan.
- After edits to `pubspec.yaml`, run `flutter pub get` and commit the updated `pubspec.lock` as appropriate for the platform.

## Documentation Expectations
- When implementing scope from `Spec.md`, document decisions and progress in the relevant ExecPlan under `.agent/`.
- When changing architecture or introducing new patterns, update the relevant ExecPlan.
- Keep `README.md` accurate for run/test commands if they change.

## Review Friendly Changes
- Keep patches small and atomic; include only directly related changes.
- Maintain existing folder structure and naming; don’t move files without clear rationale.
- Favor additive changes over large rewrites unless explicitly asked.

## Notes for Agents
- If introducing code generation (Freezed/Drift), remember to run build_runner locally to validate changes. Generated files should be checked in only if the repository already contains generated outputs.
- Be mindful of text encoding in UI strings (use proper UTF‑8 characters, e.g., `°` for degrees).
- If you need to make a potentially disruptive change (new dependency, refactor, or routing overhaul), ask for confirmation first.

