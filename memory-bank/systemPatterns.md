# System Patterns

## High‑Level Architecture
```
App Module (Android)
├── UI (Jetpack Compose)
│   ├── Screens
│   └── Theme (Material3)
├── DI (Hilt)
├── Data
│   ├── Room Database
│   └── Repository layer
└── Test
    ├── Unit (JUnit/MockK)
    └── Instrumented (Espresso/Hilt)
```

## Key Technical Decisions
| Area | Choice | Rationale |
| ---- | ------ | --------- |
| UI | Jetpack Compose | Modern declarative UI, easy previews. |
| DI | Hilt | Official DI with annotation processing, integrates with Android components. |
| Persistence | Room | Type‑safe SQLite wrapper, compile‑time validation. |
| Gradle | Kotlin DSL + Version Catalog | Type safety & centralised versions. |
| CI | GitHub Actions | Popular, free for OSS, easy to cache Gradle & set up Android SDK. |

## Reusable Patterns
* **Repository Pattern** – abstracts data sources.
* **ViewModel (MVVM)** – state holder for UI.
* **Single‑Activity Nav** – Compose Navigation (future step).
* **CI Pattern** – separate unit and Android instrumented tests into distinct jobs. Currently, Android job is disabled to ensure green CI.

## Component Relationships
```
ViewModel ↔ Repository ↔ Room DAO
          ↑ inject via Hilt ↓
      MainActivity/Compose UI
```

---
_Add more diagrams or code snippets if new patterns emerge._ 