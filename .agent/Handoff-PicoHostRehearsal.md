# Bounded host telemetry rehearsal

## Scope and ownership

- Session: `ses_f08d5ce74ffel5y2m31I9PqY9P`.
- Branch: `feat/pico-host-rehearsal`, based on reviewed PR #48 head `06d785f3f1c871a37d8dd8f6b5ed24c90ed30e35`.
- PR #48 remains draft and unchanged. This lane is host-only. The separately authorized offline spare session owns its own work; no physical evidence from it is claimed here.
- Registry `C:/github/FarmCtl/.slim/worktrees.json` records this branch and parent owner. No source lane lock was found; existing package/build locks were not changed.
- Preserve the main clone's unrelated work and ignore safeguard. No hardware, live transport, secrets, external resource records, production entrypoint, automatic activation, trust-policy changes, releases or binary distribution are in scope.

## Implementation checkpoint

Existing coordinator tests already exercised sensing failures, temperature publication retries, identity gating and cleanup using the real `Monitor`. Added exact constant fresh Celsius plus delivered diagnostics after a handled diagnostics failure using the existing synthetic identity/clock/session helper and an in-memory transport. The next unimplemented acceptance seam was the periodic heartbeat through `Monitor.step`: added healthy and sustained-failed-sensor regressions with a successful baseline at 0 ms, no heartbeat at 299,999 ms, and one at 300,000 ms while neither sensing nor temperature publication is due. The coordinator retains its 70-second bound. No production source changed.

Files: `firmware/pico/tests/test_spare_session.py`, `firmware/pico/tests/test_telemetry.py`, `tool/pico_spare/README.md`, this handoff and `.agent/ExecPlan-PicoIntegration.md`.

## Evidence

From `firmware/pico`:

```text
python -m unittest discover -s tests -p test_spare_session.py -v
python -m unittest discover -s tests -p test_telemetry.py -v
python -m unittest discover -s tests -v
```

Final implementation evidence: **20 focused session tests PASS**, **28 focused telemetry tests PASS**, **461 Pico host tests PASS**, and `git diff --check` PASS. Red evidence: an in-memory `unittest.mock.patch` delayed `runtime.should_publish_diagnostics` until 300,001 ms; both new heartbeat regressions failed at the expected 300,000 ms assertion. The patch restored automatically without source changes; focused green and full suite followed. Standards review found no documented violations. Spec review identified one P2 heartbeat evidence gap, confirmed by the third validator. Final third validation confirms P2 closed and no other worthwhile fixes. Parent inspected the final diff and whitespace check; passing broad evidence was reused, not rerun. Commit/push and stacked draft PR follow this checkpoint.

Physical acceptance: **NOT RUN in this lane**. These results do not establish live TLS/Gist, physical identity, on-device timing, watchdog or durability. Issues #45 and #43 remain OPEN/unpassed. Native verifier remains `.UNQUALIFIED`, not distributable. Physical prerequisites and permission belong to the separately authorized operator lane, not this source-only implementation.

## Context and next action

External coordinator exposes actual completed-request input + cache.read + cache.write counts, monitored every ten seconds. Latest supplied parent count is 57,575; worker maximum is 92,338 over 35 requests. Do not reuse that implementation child for more broad tasks. The coordinator interrupts at the 160,000 checkpoint guard. Completed-request counts are available; limitations concern in-flight/tool-result growth and absence of a proven runtime-enforced hard cap. All children receive concise scopes and bounded tool-round budgets; checkpoint at 160,000, stop expansion by 180,000, remain below 200,000.

Next executable action: reconcile final third validation, then publish only this validated slice as a stacked draft PR based on `feat/pico-spare-telemetry` and inspect CI for its exact head. There is no production or physical action in this lane.
