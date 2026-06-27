# AGENTS: Working on FarmCtl

This document guides Codex agents contributing to FarmCtl. It defines project layout, coding conventions, and how to run, test, and extend the app so changes remain consistent and easy to review.

## Scope
- Applies to the entire repository unless a more deeply nested `AGENTS.md` overrides it.
- Direct user instructions always take precedence over this file.

## 🤖 Autonomous Development Workflow

Default operating procedure for any coding agent (Claude Code or Codex, local **or**
cloud session) given a task in this repo. Follow it unless the user explicitly opts out.

### 1. Triage the request
- **Small / low-risk change** (typo, small bug fix, doc tweak, config nudge — roughly
  under ~50 lines, no architectural impact, unambiguous intent): just do it. Run the
  relevant tests, then commit and push **directly to `master`**. No branch, no PR.
- **Larger change** (new feature, refactor, anything ambiguous or cross-cutting): follow
  the full pipeline below.

### 2. Clarify — the FIRST and one of only TWO points where questions are allowed
Before writing code on a larger change, ask the user concise clarification questions to
(a) confirm exactly what they want and (b) surface gaps or risks they may have missed
(missing secrets, breaking changes, edge cases). Batch the questions together.
**After this step the flow is fully autonomous until the PR is opened — do not ask the
user anything in between.**

### 3. Plan & branch
- Write a short plan: the target end state and the work split into small iterations.
- For substantial features, create/maintain an ExecPlan under `.agent/` (see below).
- Create a feature branch `feat/<slug>` (or `fix/<slug>`); all work happens there.

### 4. Iterate
For each iteration:
1. Implement the slice.
2. Regenerate code if needed: `dart run build_runner build --delete-conflicting-outputs`.
3. Run tests with coverage: `flutter test --coverage` in `app/`, `dart test` in
   `packages/farmctl_parsing`. **Coverage must stay at or above the CI baseline** — add
   tests for new code.
4. Run a code-review pass and apply the fixes it surfaces.
5. Proceed to the next iteration.

### 5. Reviews
- Routine per-iteration review: a single focused pass is fine.
- **Bigger reviews** (whole feature, risky or security-sensitive changes): run **at least
  two review agents with different focuses** (e.g. correctness/logic vs.
  security/robustness, or API design vs. test coverage) **plus a third validator agent**
  that goes over their findings, discards false positives, and produces the concrete
  list of issues that are actually worth fixing. Then fix them.

### 6. Final review & PR
- After the last iteration, run a **deeper review over the whole feature**: confirm
  everything is tested, coverage is healthy, and analyze/format/tests are green.
- Open a PR with a **concise** description: what changed and what is delivered (not a
  blow-by-blow log).
- Opening the PR is the **only** other point (besides step 2) where questions to the user
  are allowed. In chat, post a short summary and **list open questions only if there
  genuinely are any** — the goal is none.

### 7. Merge & release
- On user approval, merge the PR to `master`, then **bump `version:` in
  `app/pubspec.yaml` and push a matching `v<version>` tag**.
- The tag triggers CI to build a **signed release APK** and publish a GitHub release
  (see `.github/workflows/`). Plain direct-to-`master` commits do **not** cut releases.

### Guardrails
- Never commit secrets, keystores, or `key.properties` (all gitignored).
- Keep `app/pubspec.lock` committed; do not float dependency versions.
- Keep diffs focused and follow the coding conventions below.

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
- **Always run** `dart run build_runner build --delete-conflicting-outputs` from `app/` before running
  `flutter analyze` or any tests so generated types stay in sync.

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

