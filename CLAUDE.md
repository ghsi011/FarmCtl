# FarmCtl

Flutter app for monitoring and controlling farm thermostats.
Full contributor guide (layout, conventions, architecture, commands):

@AGENTS.md

## Notes for Claude Code
- Dev environment is Windows + PowerShell; run Flutter/Dart commands from `app/`.
- **Always** run `dart run build_runner build --delete-conflicting-outputs` from `app/`
  before `flutter analyze` or `flutter test` — generated Drift/Freezed types must stay in sync.
- Check `.agent/` for an active ExecPlan before starting complex features or refactors.
