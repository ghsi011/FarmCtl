"""Focused regressions for trial reporter fencing and post-commit behavior."""

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PICO = ROOT / 'firmware' / 'pico'
TESTS = PICO / 'tests'
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(PICO))
sys.path.insert(0, str(TESTS))

import test_firmware_trial_proof as proof_harness


class FirmwareTrialReporterEdgeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = proof_harness.Harness()
        self.fixture.setUp()

    def tearDown(self):
        self.fixture.tearDown()

    def _new_monitor(self):
        from firmware.pico.runtime import Monitor
        return Monitor(proof_harness.Sensor(), self.fixture.publisher, self.fixture.clock,
                       'untrusted-candidate-boot', 'device-ref', 'pico-2')

    def test_rejected_binding_fences_supplied_monitor_before_validation(self):
        fixture = self.fixture
        fixture.stage()
        cases = (
            ('invalid marker', 'unsafe/marker', fixture.registered_gist_ids,
             fixture.firmware._verify_slot),
            ('wrong Gists', 'trial-marker-2', {
                'thermostat.txt': 'c' * 32,
                'diagnostics.json': 'b' * 32,
            }, fixture.firmware._verify_slot),
            ('verifier exception', 'trial-marker-2', fixture.registered_gist_ids,
             lambda slot, release_id: (_ for _ in ()).throw(RuntimeError('secret'))),
        )
        for label, marker, gist_ids, verifier in cases:
            with self.subTest(reason=label):
                candidate = self._new_monitor()
                self.assertFalse(candidate._publication_suspended)
                self.assertFalse(fixture.reporter.bind_launch(
                    'B', 2, marker, candidate, verifier, gist_ids))
                self.assertTrue(candidate._publication_suspended)
                before = list(fixture.events)
                self.assertIsNone(candidate.poll())
                self.assertIsNone(candidate.step(10, 60))
                self.assertEqual(fixture.events, before)

    def test_commit_hook_is_network_free_updates_applied_state_and_preserves_heartbeat(self):
        fixture = self.fixture
        fixture.stage()
        candidate = fixture.launches[-1][1]
        # Leave only a short amount of the proof window, while the proof itself
        # remains fast in this deterministic fake transport.
        fixture.clock.now = 284000
        requests = []
        publisher = fixture.publisher
        patch = publisher.patch_exact_for_trial
        confirm = publisher.confirm_file

        def track_patch(*args, **kwargs):
            requests.append(('patch', args[0]))
            return patch(*args, **kwargs)

        def track_confirm(*args, **kwargs):
            requests.append(('confirm', args[1]))
            return confirm(*args, **kwargs)

        publisher.patch_exact_for_trial = track_patch
        publisher.confirm_file = track_confirm
        self.assertTrue(fixture.fixed.run_operation(
            'firmware', lambda: fixture.firmware.trial_ok(2, 'trial-marker-2', True)))
        before_hook = len(requests)
        trial_report = json.loads(fixture.events[2][3])
        emitted_heartbeat = trial_report['heartbeat_seq']
        self.assertGreaterEqual(candidate.diagnostics['heartbeat_seq'], emitted_heartbeat)

        # A network request here would consume 30 seconds and is forbidden.
        def forbidden(*args, **kwargs):
            fixture.clock.now += 30000
            raise RuntimeError('post-commit network attempt')

        publisher.patch_exact_for_trial = forbidden
        publisher.confirm_file = forbidden
        self.assertTrue(fixture.reporter.after_confirmed_selection(2, 'trial-marker-2'))
        self.assertEqual(len(requests), before_hook)
        self.assertFalse(candidate._publication_suspended)
        self.assertEqual(candidate.diagnostics['firmware']['last_attempt'], {
            'release_id': 2, 'trial_marker': 'trial-marker-2',
            'state': 'applied', 'reason': None,
        })
        self.assertEqual(candidate.diagnostics['firmware']['retained_good'], 'pico-1')
        self.assertGreaterEqual(candidate.diagnostics['heartbeat_seq'], emitted_heartbeat)

        # Ordinary reporting owns subsequent heartbeat increments.
        candidate.diagnostics['heartbeat_seq'] += 1
        self.assertGreater(candidate.diagnostics['heartbeat_seq'], emitted_heartbeat)


if __name__ == '__main__':
    unittest.main()
