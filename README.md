# FarmCtl

FarmCtl is a smart-thermostat monitoring client targeting Android. The Flutter workspace is located in [`app/`](app/).

## Getting Started

### Prerequisites
You can either install Flutter globally or use the repository-managed SDK bootstrap described below.

1. Enable Android toolchain support and accept the Android SDK licenses.
2. Start an Android emulator or connect a device with developer mode enabled.

#### Repository-managed Flutter SDK

The repository includes helper scripts that download the Flutter SDK into `.tooling/flutter` and expose a shell environment with the correct `PATH`.

```bash
./tool/setup_flutter.sh          # downloads/updates the SDK
source ./tool/flutter_env.sh     # adds flutter and dart to PATH for the current shell
flutter doctor                   # optional health check
```

You can add `source /path/to/repo/tool/flutter_env.sh` to your shell profile if you want the SDK available automatically whenever you work on FarmCtl.

### Running the App
```bash
cd app
flutter pub get
flutter run
```

The application launches with Material 3 theming, Riverpod-provided state management, and a bottom navigation bar exposing the Thermostats and Settings tabs. The Thermostats tab shows a static thermostat card that will be replaced with live data in future iterations.

### Quality Checks

Run the automated checks before pushing to ensure the CI workflow will pass:

```bash
cd app
flutter pub get
dart format .
flutter analyze
flutter test
flutter build apk --debug

# Dart-only unit tests
cd ../packages/farmctl_parsing
dart test
```

The repository includes a [`.pre-commit-config.yaml`](.pre-commit-config.yaml) that formats changed Dart files and runs `flutter analyze`. After installing [`pre-commit`](https://pre-commit.com/#install), enable the hooks with `pre-commit install`.

### Project Structure Highlights
- `lib/` — Flutter source code organised by feature, including navigation (`core/router`) and feature modules (`features/thermostats`, `features/settings`).
- `pubspec.yaml` — Dependency manifest including Riverpod, GoRouter, Freezed annotations, Dio, and Drift for future iterations.
- `test/` — Placeholder widget test scaffolding for future coverage.

Refer to [`Spec.md`](Spec.md) and [`docs/ImplementationPlan.md`](docs/ImplementationPlan.md) for the product roadmap and architectural guidance.
