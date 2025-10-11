# Smart Thermostat Management App — Generation-Ready Specification (Android)

> **Goal**: This document is a 4th-level “executable” spec. A capable AI should be able to generate a complete Android app (code, tests, assets, build config) from it without deciding architecture or UX details on its own. Any unspecified choice (framework, language) is left to the implementer as long as the **Android behavior and contracts** below are met.

* This document should be updated and iterated upon during development.

---

## 1) Scope & Non-Goals

**In-scope**

* Manage multiple remote thermostats whose **current temperature** is read from **GitHub Gist raw URLs**.
* Add/remove thermostats at runtime; each has its own **name**, **source URL**, and **operating range** (min/max in °C).
* Background **watchdog** that continuously monitors sensors and triggers **audible alarms** (Android alarm-app-like behavior) when values go out of range.
* Historical graphs over: **1h, 24h, 7d, 30d, 365d, all-time**, using **Gist revision history**.
* Configurable alarm sound using **system sound picker** (alarms/tones/music).
* Works on **Android smartphones** (Android 14.0+). Tablet support optional.
* Full automated test coverage: unit + instrumentation/system tests.

**Out of scope**

* iOS/web/desktop clients.
* Controlling the physical thermostat (write operations). This app is **read-only** telemetry + alarms.
* Cloud accounts other than GitHub Gist (no Dropbox/Drive).

---

## 2) Definitions & Assumptions

* **Thermostat Source**: A public GitHub Gist *raw* URL that, when fetched, returns a **single-line** payload in English:
  `Temperature: <float> C` (example: `Temperature: 8.13 C`).
  Optional whitespace is allowed. Case-insensitive keys “Temperature” and “C” must be accepted.
* **History Source**: The Gist’s **revisions** list; each revision’s raw content is parsed as above; the revision’s **commit timestamp** is the sample time.
* **Units**: Celsius only (UI can show °C symbol; no °F conversion).
* **Sampling cadence**: Configurable polling (default: **every 5 minutes**) with jitter (±30 sec) to avoid thundering herd and rate limits.
* **Connectivity**: App must tolerate offline periods; cache last known values and history locally.
* **Privacy**: All thermostat URLs are stored locally; no analytics or telemetry is sent by the app.

---

## 3) Functional Requirements

### 3.1 Thermostat CRUD

* **Add thermostat**

  * Inputs: `name` (1–40 chars), `rawUrl` (https URL), `minC` (float), `maxC` (float).
  * Validation:

    * `rawUrl` must be HTTPS and match GitHub Gist raw pattern or be a valid HTTPS URL that returns a temperature line (allow general HTTPS to avoid over-fitting).
    * On save, app **tests** the URL once: HTTP 200 within 10s, parse temperature; if parse fails → show blocking error and **do not** persist.
    * `minC < maxC` and both within **[-80.0, 200.0]**.
* **Edit thermostat**

  * All fields editable; URL re-validated on change.
* **Remove thermostat**

  * Immediate, with confirmation. Removes local cached history for that thermostat.

### 3.2 Operating Range

* Per-thermostat `minC`, `maxC`.
* **Out-of-range** defined as `temp < minC` OR `temp > maxC`.
* **Hysteresis**: Optional UI toggle. If enabled, re-entry into range requires a **1.0°C buffer** inside the range to prevent alarm chatter.

### 3.3 Read Current Temperature

* **Fetch** using HTTP GET to the configured raw URL.
* **Parse** tolerant regex (case-insensitive, spaces optional):
  `^.*?Temperature\s*:\s*([-+]?\d+(?:\.\d+)?)\s*C.*$`
* **Timestamp**: server time is not trusted; use **device receive time** for current reading, **revision timestamp** for history.
* **Caching**: Store reading with time; display last-seen with relative time (e.g., “Updated 3 min ago”).

### 3.4 History via Gist Revisions

* **List revisions** for the Gist (HTTP API). For each revision:

  * Obtain the raw content for that revision’s file.
  * Parse temperature using the same regex.
  * Use the revision’s **commit timestamp** as sample time (UTC). Convert to local time in UI.
* **Aggregation**

  * For spans larger than 7d, allow downsampling (e.g., 15-min or hourly buckets) with min/avg/max for performance.
  * Store normalized samples in local DB keyed by thermostat + revision sha/time.
* **Ranges**: last hour, day, week, month, year, all-time.
* **Progressive loading**: Render as data streams in; show a loading indicator and partial graph.

### 3.5 Background Watchdog & Alarms

* **Goal**: Behavior comparable to Android’s clock alarms—reliable, audible alerts even under Doze.
* **Mechanics**

  * Schedule periodic checks (default every 5 min; user-configurable 1–30 min).
  * Use a **Foreground Service** during checks to comply with background limits.
  * For out-of-range detection:

    * Create a **high-priority notification** with full-screen intent and sound/vibrate using the **user-selected tone**.
    * **Snooze** action (5/10/30 min) and **Silence until back in range** action.
  * **Exact alarms**: If user enables “critical alarms,” schedule **exact** follow-up checks using system APIs that work under Doze. If OS requires permission for exact alarms, app must request and degrade gracefully when denied.
  * **Rate limiting**: Do not alarm more than once per thermostat per **5 minutes**, unless re-armed by user or state changes back to OK and out again (with hysteresis handling).
* **Alarm sound selection**

  * Use system sound picker to allow: Alarm tones, Ringtones, Music files.
  * Persist URI permission where needed; test playback on selection.

### 3.6 Global & Per-Thermostat Controls

* **Per-thermostat**: enable/disable monitoring; edit name/URL/range; open details (current value, history, last error).
* **Global**: pause all monitoring for a duration (e.g., 1h, 8h, until next day).

### 3.7 Error Handling & Health

* **Network errors**: exponential backoff (max 30 min) while preserving a **status** indicator in UI.
* **Parse errors**: mark thermostat as **invalid payload**; show last good value and error badge.
* **HTTP status**: 4xx/5xx recorded; 401/403 highlighted (private or revoked Gist).
* **Rate limit**: Detect GitHub API rate limiting; automatically throttle polling for affected sensors, surface a banner suggesting longer intervals.
* **Diagnostics screen**: last 50 events per thermostat (fetch time, status, parsed temp or error).

---

## 4) Non-Functional Requirements

### 4.1 Performance

* Home list loads in <300ms from cold start (with cached data).
* Graph renders <500ms for 1k points; downsample above that threshold.
* Memory target <150MB on mid-range device while viewing 1 graph.

### 4.2 Reliability

* Background checks continue across reboots (register boot receiver; re-schedule tasks).
* If the OS force-closes the app, monitoring resumes on next OS window for background execution according to platform constraints.

### 4.3 Security & Privacy

* **No credentials** required for public gists. If private gists are introduced later, design supports a **token field** stored in encrypted preferences.
* Store URLs and preferences locally; no third-party analytics.
* Respect scoped storage and URI permissions for sounds.

---

## 5) Data Model (Local)

Use a relational store (e.g., SQLite) with the following conceptual schema:

* `Thermostat`
  `id (UUID)`, `name (TEXT)`, `rawUrl (TEXT)`,
  `minC (REAL)`, `maxC (REAL)`, `hysteresisEnabled (BOOL)`,
  `monitoringEnabled (BOOL)`, `createdAt (TS)`, `updatedAt (TS)`

* `Reading`
  `id (UUID)`, `thermostatId (FK)`, `source ("current"|"revision")`,
  `valueC (REAL)`, `observedAt (TS)`, `sourceId (TEXT|NULL)`  // revision sha or null

* `AlertConfig` (one row global)
  `pollIntervalMin (INT)`, `exactAlarmsEnabled (BOOL)`,
  `soundUri (TEXT|NULL)`, `vibrate (BOOL)`, `volumeBoost (BOOL)`

* `ThermostatState` (derived/cache)
  `thermostatId (FK)`, `lastFetchAt (TS|NULL)`, `lastStatus ("OK"|"OUT_OF_RANGE"|"NETWORK_ERROR"|"PARSE_ERROR"|"AUTH_ERROR")`,
  `lastValueC (REAL|NULL)`, `lastAlarmAt (TS|NULL)`

* `EventLog`
  `id`, `thermostatId`, `time`, `level ("INFO"|"WARN"|"ERROR")`, `message`

**Indexes**: `Reading(thermostatId, observedAt DESC)`, `Thermostat(name)`, `EventLog(time DESC)`.

---

## 6) External Integration Contracts (GitHub Gist)

### 6.1 Current Reading Contract

* **Input**: `rawUrl` (HTTPS).
* **Request headers**: `Accept: text/plain`, `If-None-Match` (use ETag when available).
* **Timeout**: connect 5s, read 10s.
* **Retries**: up to 2 with backoff.

**Expected Response (examples)**

```
Temperature: 8.13 C
Temperature: -3 C
temperature: 12.0 c
```

**Parsing**: single value float; ignore additional lines if present; take first match.

### 6.2 History Contract

* **List revisions** for the Gist containing the target file; for each revision:

  * Construct raw URL for that revision.
  * Fetch and parse as above.
  * Use **revision commit timestamp** as `observedAt`.
* **Pagination**: iterate until reaching the requested time range or page limit.
* **Rate limits**: If API quotas are hit, back off and suggest increasing poll interval.

---

## 7) User Interface Specification

### 7.1 Navigation

* Bottom navigation with two tabs: **Thermostats**, **Settings**.
* From Thermostats list, tap an item to **Details** (stack push).
* Global **FAB** on list to add a thermostat.

### 7.2 Screens

**A) Thermostats List**

* Header: “Thermostats” + search.
* Cards per thermostat:

  * Name; colored status dot (green OK, red Out of Range, yellow Error).
  * Last value: `8.1°C` and “Updated 3m ago”.
  * Range pill: `4–10°C`.
  * Toggle: **Monitor** on/off.
  * Overflow: Edit, View history, Remove.

**B) Add/Edit Thermostat**

* Fields: Name (text), URL (text), Min °C (numeric), Max °C (numeric), Hysteresis (switch), Monitoring (switch).
* “Test & Save” button (does a real fetch, shows parsed temp).
* Validation errors inline under fields.

**C) Thermostat Details**

* Header: Name + status chip.
* Current panel: Big numeric `8.13°C`, range, last updated, quick controls: Snooze, Silence.
* Graph panel: timeline selector (1h / 1d / 1w / 1m / 1y / All). Interactive pan/zoom; data point tooltip (time, value).
* Diagnostics: last fetch status, last 10 log lines.

**D) Settings**

* Monitoring: Poll interval slider (1–30 min), “Allow exact alarms” switch (explains permission), “Pause all monitoring” (duration chips).
* Alarm: “Choose sound” (opens system picker), vibrate switch, “Test alarm” button.
* Data: “Rebuild history” (re-pull revisions for selected thermostat), “Export data” (CSV per thermostat).
* About: version, licenses, privacy.

**E) Alarm/Alert Surface**

* Full-screen, dismiss-keyguard presentation with:

  * Thermostat name, current temp, reason (e.g., “Below 4°C”).
  * Buttons: **Snooze 10m**, **Silence until OK**, **Open App**.
  * Plays chosen sound at alarm stream; respects hardware volume keys.

### 7.3 Accessibility & i18n

* All UI copy in a single resource bundle; support RTL layouts.
* Color states paired with text/icons; minimum 4.5:1 contrast.
* Content descriptions on interactive elements.

---

## 8) Background Execution Strategy (Android)

* Use a **persistent scheduler** that:

  * Reschedules after device reboot (boot completed receiver).
  * Performs work in a **Foreground Service** while fetching/parsing to comply with background limits.
  * When **exact alarm** permission is granted (Android 12+), schedule **setExactAndAllowWhileIdle** follow-ups for critical alarms. Otherwise, use the recommended flexible scheduler (periodic work with constraints) and raise user guidance if reliability is compromised by OEM restrictions.
* Watchdog state machine:

  1. `IDLE` → periodic trigger → `CHECKING`
  2. `CHECKING` fetches all enabled thermostats (sequentially with per-host concurrency = 2).
  3. For each: classify (`OK` | `OUT_OF_RANGE` | `ERROR`); update DB; possibly `ALARMING`.
  4. `ALARMING` posts high-priority notification and full-screen intent.
  5. `ACKNOWLEDGED` on snooze/silence; schedule next check accordingly.
* Respect Doze/App Standby by running critical parts as Foreground with short lifetime.

---

## 9) Telemetry Storage & Retention

* **Readings**: keep all for 1 year; beyond 1 year keep **downsampled** hourly min/avg/max; raw points older than 18 months may be purged.
* **EventLog**: cap to 5,000 records (oldest first eviction).
* **Exports**: user can export CSV per thermostat and selected range.

---

## 10) Error Messages (Canonical)

* URL invalid: “That doesn’t look like a valid HTTPS URL.”
* Fetch timeout: “Couldn’t reach the thermostat (timeout).”
* HTTP error: “The server responded with <code>.”
* Parse error: “Content didn’t include a ‘Temperature: … C’ line.”
* Range invalid: “Minimum must be less than maximum.”
* Rate limited: “GitHub is rate-limiting requests. Monitoring slowed; try a longer interval.”

All error strings must be centralized for localization.

---

## 11) Test Plan

### 11.1 Unit Tests

* **Parsing**: variations in case/whitespace, negative values, decimals, extra text.
* **Range logic**: boundaries, hysteresis on/off, flapping prevention.
* **Scheduler**: next-run computation, snooze math, silence-until-OK transitions.
* **Reducers/DB**: CRUD correctness, indexing, retention pruning.

### 11.2 Integration/Instrumentation Tests

* **Add/Edit flow**: enter URL, test & save, verify card shows value.
* **History graph**: mock revisions list with 10k points; verify downsampling & tooltips.
* **Alarm surface**: simulate out-of-range; verify full-screen UI, actions (snooze/silence), sound playback via mockable audio layer.
* **Reboot persistence**: enable monitoring, simulate reboot, verify reschedule.
* **Offline**: take network down; ensure graceful degradation and caching.

### 11.3 System/E2E Tests

* **Scenario A**: Two thermostats, different ranges; one goes below min, the other OK → single alarm fires for the failing one, no duplicate.
* **Scenario B**: Parse error then recovery → error badge clears and state returns to OK without user action.
* **Scenario C**: Rate limit → app backs off and surfaces banner.
* **Scenario D**: User denies exact-alarm permission → app still monitors using flexible scheduler; show guidance.

**Coverage target**: ≥90% lines for core modules (parsing, range, scheduler, alarm), ≥80% overall.

---

## 12) Architecture & Modularity (Technology-Agnostic)

* **Layers**

  * **Data**: HTTP client, GitHub API wrapper, DB repositories, cache.
  * **Domain**: Entities, use-cases (AddThermostat, FetchCurrent, BuildHistory, EvaluateRange, ScheduleNext, RaiseAlarm).
  * **Presentation**: View models/state containers; pure render components.
  * **System**: Background scheduler, foreground service, notifications & alarms, boot receiver.
* **Dependency Rules**: Presentation → Domain → Data; System can invoke Domain use-cases.
* **Abstractions to enforce**:

  * `Clock` (testable time).
  * `Net` (HTTP with interceptors, ETag, retries).
  * `Audio` (play, stop, list/resolve URIs).
  * `Scheduler` (periodic, exact).
  * `Store` (preferences + database).

---

## 13) Permissions & Compliance

* **INTERNET**
* **POST_NOTIFICATIONS** (Android 13+)
* **FOREGROUND_SERVICE** (and sub-types if required by target SDK)
* **SCHEDULE_EXACT_ALARM** (Android 12+, request only if user enables critical alarms)
* **READ/WRITE_EXTERNAL_STORAGE**: **Not required**; use storage access framework/URI permissions for chosen sound.

Display clear rationale dialogs where needed.

---

## 14) Settings & Defaults

* Poll interval: **5 min** (range 1–30).
* Hysteresis: **On** by default (1.0°C).
* Exact alarms: **Off** by default (guided opt-in).
* Default sound: system **Alarm** stream default.
* Vibrate: **On** by default.

---

## 15) Analytics & Logging

* No network analytics. Local `EventLog` only.
* Optional developer toggle in Settings to export logs to file.

---

## 16) Internationalization

* Provide strings in English; structure for additional locales.
* Date/time formatting uses device locale.

---

## 17) Deliverables Checklist (for the AI generator)

* Android app project (SDK 26+), with:

  * Implemented screens & flows per **UI Specification**.
  * Background watchdog with **Foreground Service**, notifications, and optional **exact alarms**.
  * GitHub Gist integration per **Contracts** (current + revisions).
  * Local DB models and migration scripts.
  * Sound picker integration; alarm surface with full-screen intent.
  * Accessibility support (labels, contrast).
  * Comprehensive tests per **Test Plan** (unit, instrumentation, E2E).
  * CI config to run tests and produce a signed debug APK.
  * README covering permissions, limitations under OEM power management, and steps to enable exact alarms.

---

## 18) Acceptance Criteria

1. Can add a thermostat with the provided example URL; app shows a parsed temperature within 10s.
2. Can configure min/max; when the value crosses the threshold, an audible full-screen alarm appears, with snooze/silence actions that work.
3. History graph populates for “All” by walking revisions and displays tooltips with correct timestamps.
4. After device reboot, monitoring continues without user opening the app.
5. With network off, the app shows last known values and a visible error; no crashes.
6. Tests pass locally and in CI; coverage thresholds met.

---

## 19) Future-Proofing Hooks (do not implement now)

* Fahrenheit display toggle.
* Private Gists with personal access tokens (encrypted at rest).
* Webhooks/push model to reduce polling.
* Multi-file Gists / multiple metrics (humidity).
