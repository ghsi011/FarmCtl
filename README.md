# FarmCtl

FarmCtl is a smart-thermostat monitoring client targeting Android. The Flutter workspace is located in [`app/`](app/).

## Getting Started

### Prerequisites
1. [Install Flutter](https://docs.flutter.dev/get-started/install) (3.16 or newer recommended).
2. Enable Android toolchain support and accept the Android SDK licenses.
3. Start an Android emulator or connect a device with developer mode enabled.

### Running the App
```bash
cd app
flutter pub get
flutter run
```

The application launches with Material 3 theming, Riverpod-provided state management, and a bottom navigation bar exposing the Thermostats and Settings tabs. The Thermostats tab shows a static thermostat card that will be replaced with live data in future iterations.

### Project Structure Highlights
- `lib/` — Flutter source code organised by feature, including navigation (`core/router`) and feature modules (`features/thermostats`, `features/settings`).
- `pubspec.yaml` — Dependency manifest including Riverpod, GoRouter, Freezed annotations, Dio, and Drift for future iterations.
- `test/` — Placeholder widget test scaffolding for future coverage.

Refer to [`Spec.md`](Spec.md) and [`docs/ImplementationPlan.md`](docs/ImplementationPlan.md) for the product roadmap and architectural guidance.
