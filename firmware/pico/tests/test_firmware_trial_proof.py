"""Synthetic host launch harness; it never executes candidate .mpy files."""

import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PICO = ROOT / 'firmware' / 'pico'
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(PICO))

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from firmware.pico.firmware_supervisor import FirmwareSupervisor
from firmware.pico.firmware_trial_proof import FirmwareTrialReporter
from firmware.pico.fixed_supervisor import FixedSupervisor
from firmware.pico.gist_publisher import GistPublisher, DIAGNOSTICS_FILENAME, THERMOSTAT_FILENAME
from firmware.pico.gist_readback import GistReadback
from firmware.pico.runtime import Monitor
from firmware.pico.update_state import UpdateState, UpdateStateStore
from tool.pico_release.manifest import build_candidate


ASSETS = {'app.mpy': b'candidate-app-bytes', 'lib/sensor.mpy': b'signed-sensor-bytes'}
TEMPERATURE_GIST = 'a' * 32
DIAGNOSTICS_GIST = 'b' * 32


class Clock:
    def __init__(self, now=1000, modulus=None):
        self.now = now
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus if self.modulus else self.now

    def ticks_diff(self, current, previous):
        if not self.modulus:
            return current - previous
        half = self.modulus // 2
        return (current - previous + half) % self.modulus - half


class Sensor:
    def __init__(self, value=21.25):
        self.value = value
        self.reads = 0

    def read_celsius(self):
        self.reads += 1
        return self.value


class Slot:
    def __init__(self, raw, signature, assets):
        self.raw, self.signature, self.assets = raw, signature, dict(assets)

    def list_assets(self):
        return list(self.assets)

    def open_asset(self, path):
        return io.BytesIO(self.assets[path])


class ProofTransport:
    """Fake network boundary which still exercises strict publisher/readback."""

    def __init__(self, events):
        self.events = events
        self.files = {}
        self.get_mismatch = False
        self.patch_error = None
        self.after_diagnostics_get = None

    def patch_gist(self, gist_id, body, service=None):
        if self.patch_error is not None:
            raise RuntimeError(self.patch_error)
        payload = json.loads(body.decode('utf-8'))
        filename, info = next(iter(payload['files'].items()))
        self.events.append(('PATCH', gist_id, filename, info['content']))
        self.files[(gist_id, filename)] = info['content']

    def get_gist_json(self, gist_id, sink, service=None):
        filename = THERMOSTAT_FILENAME if gist_id == TEMPERATURE_GIST else DIAGNOSTICS_FILENAME
        content = self.files.get((gist_id, filename), '')
        if self.get_mismatch:
            content += ' altered'
        self.events.append(('GET', gist_id, filename, content))
        sink(json.dumps({
            'id': gist_id, 'truncated': False,
            'files': {filename: {'content': content}},
        }).encode('utf-8'))
        if filename == DIAGNOSTICS_FILENAME and self.after_diagnostics_get is not None:
            self.after_diagnostics_get()


class ConfigStub:
    state = {'status': 'ready'}

    def load(self):
        return self.state

    def recover_after_boot(self):
        return 'ready'


class Harness(unittest.TestCase):
    # The harness models the trusted single-owner firmware supervisor invariant;
    # it does not attempt to stop a malicious external actor resuming a monitor.
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.slots = {}
        self.events = []
        self.launches = []
        self.store = UpdateStateStore(self.temp.name)
        self.store.initialize({
            'applied_slot': 'A', 'applied_id': 1,
            'retained_slot': 'B', 'retained_id': 1,
            'installed_high_water': 1, 'failed_high_water': 0,
            'pending_slot': None, 'pending_id': None,
            'trial_marker': None, 'phase': None,
        })
        self.state = UpdateState(self.store, self.clock.ticks_ms, self.clock.ticks_diff)
        raw, sig = build_candidate(1, 'v1.29.0', ASSETS, self.private)
        self.slots['A'] = Slot(raw, sig, ASSETS)
        self.publisher = self.make_publisher()
        # Synthetic boot-verified applied configuration registration.
        self.registered_gist_ids = dict(self.publisher.gist_ids)
        self.old_monitor = Monitor(Sensor(), self.publisher, self.clock, 'old-boot',
                                   'device-ref', 'pico-1')
        self.current_monitor = self.old_monitor
        self.reporter = FirmwareTrialReporter(self.state, self.clock.ticks_ms,
                                              self.clock.ticks_diff)
        self.firmware = FirmwareSupervisor(
            self.state, self.public, self.verify_signature, 'RPI_PICO2_W', 'v1.29.1',
            self.read_slot, self.write_slot, self.launch, self.clock.ticks_ms,
            self.clock.ticks_diff, self.reporter)
        self.fixed = FixedSupervisor(ConfigStub(), self.firmware, '/config', 'device-ref')
        # Harness setup stands in for successful fixed boot; operations still use
        # FixedSupervisor's real shared firmware-operation guard.
        self.fixed._booted = True

    def tearDown(self):
        self.temp.cleanup()

    def make_publisher(self):
        publisher = object.__new__(GistPublisher)
        publisher.gist_ids = {
            THERMOSTAT_FILENAME: TEMPERATURE_GIST,
            DIAGNOSTICS_FILENAME: DIAGNOSTICS_GIST,
        }
        publisher.transport = ProofTransport(self.events)
        publisher.readback = GistReadback(publisher.transport, TEMPERATURE_GIST,
                                          DIAGNOSTICS_GIST)
        publisher.time_is_trusted = lambda: True
        publisher.service = None
        publisher._closed = False
        publisher.clock = self.clock
        publisher._backoff = {
            name: {'failures': 0, 'last_failure': None, 'delay': 0}
            for name in publisher.gist_ids
        }
        publisher._server_not_before = None
        publisher._failure_count = 0
        return publisher

    def verify_signature(self, signature, key, message):
        try:
            self.private.public_key().verify(signature, message)
            return key == self.public
        except Exception:
            return False

    def read_slot(self, slot):
        image = self.slots[slot]
        return image.raw, image.signature, image

    def write_slot(self, slot, candidate, raw, signature):
        self.slots[slot] = Slot(raw, signature, ASSETS)

    def launch(self, slot):
        state = self.state.state
        release_id, marker = state['pending_id'], state['trial_marker']
        # This synthetic launch only binds the signed slot to a newly-created
        # monitor. It does not execute app.mpy or establish physical execution.
        candidate = self.firmware._verify_slot(slot, release_id)
        monitor = Monitor(Sensor(), self.publisher, self.clock,
                          'candidate-boot-' + str(candidate.release_id),
                          'device-ref', 'pico-' + str(candidate.release_id))
        self.assertTrue(monitor.suspend_publication())
        self.launches.append((slot, monitor))
        self.assert_binding = self.reporter.bind_launch(
            slot, release_id, marker, monitor, self.firmware._verify_slot,
            self.registered_gist_ids)

    def stage(self, release_id=2, marker=None):
        marker = marker or 'trial-marker-' + str(release_id)
        raw, sig = build_candidate(release_id, 'v1.29.0', ASSETS, self.private)
        # Old publication is stopped before metadata staging begins.
        self.assertTrue(self.current_monitor.suspend_publication())
        self.fixed.run_operation('firmware', lambda: self.firmware.admit_and_stage(
            raw, sig, 'pico-' + str(release_id), marker))
        self.assertTrue(self.assert_binding)

    def finish(self, release_id, marker):
        confirmed = self.fixed.run_operation(
            'firmware', lambda: self.firmware.trial_ok(release_id, marker, True))
        if confirmed is True:
            # Once metadata selection is durable, the candidate is the only current
            # monitor. Resume failure is recovery-required, never a rollback signal.
            self.current_monitor = self.launches[-1][1]
            self.recovery_required = not self.reporter.after_confirmed_selection(
                release_id, marker)
        return confirmed

    def run_scheduler_turn(self, monitor):
        """Ordinary postcommit callback: diagnostics are best effort, not gating."""
        return monitor.poll()

    def fail_and_restore_old_monitor(self):
        self.fixed.run_operation('firmware', self.firmware.fail_trial)
        state = self.state.state
        self.firmware._verify_slot(state['applied_slot'], state['applied_id'])
        self.current_monitor.resume_publication()
        self.assertIs(self.current_monitor, self.old_monitor)
        self.assertFalse(self.old_monitor._publication_suspended)
        self.assertTrue(all(monitor._publication_suspended
                            for _, monitor in self.launches))

    def test_signed_fresh_monitor_proves_both_gists_before_durable_promotion(self):
        self.stage()
        monitor = self.launches[-1][1]
        self.assertEqual(monitor.boot_id, 'candidate-boot-2')
        self.assertTrue(self.finish(2, 'trial-marker-2'))
        self.assertEqual([e[0:3] for e in self.events[:4]], [
            ('PATCH', TEMPERATURE_GIST, THERMOSTAT_FILENAME),
            ('GET', TEMPERATURE_GIST, THERMOSTAT_FILENAME),
            ('PATCH', DIAGNOSTICS_GIST, DIAGNOSTICS_FILENAME),
            ('GET', DIAGNOSTICS_GIST, DIAGNOSTICS_FILENAME),
        ])
        diagnostics = json.loads(self.events[2][3])
        self.assertEqual(diagnostics['sensor']['last_sample_ref'], 'candidate-boot-2:1')
        self.assertEqual(diagnostics['firmware']['last_attempt'], {
            'release_id': 2, 'trial_marker': 'trial-marker-2',
            'state': 'trial', 'reason': None,
        })
        self.assertEqual(diagnostics['firmware']['retained_good'], 'pico-1')
        self.assertGreaterEqual(diagnostics['heartbeat_seq'], 1)
        self.assertEqual(self.state.state['applied_id'], 2)
        self.assertEqual(len(self.events), 4)
        self.assertEqual(monitor.diagnostics['firmware']['last_attempt']['state'], 'applied')
        self.assertEqual(monitor.diagnostics['firmware']['retained_good'], 'pico-1')
        heartbeat_before = monitor.diagnostics['heartbeat_seq']
        self.run_scheduler_turn(monitor)
        self.assertGreater(monitor.diagnostics['heartbeat_seq'], heartbeat_before)
        self.assertEqual(monitor.diagnostics['firmware']['last_attempt']['state'], 'applied')
        self.assertEqual(monitor.diagnostics['firmware']['retained_good'], 'pico-1')
        self.assertEqual([e[0:3] for e in self.events[:4]], [
            ('PATCH', TEMPERATURE_GIST, THERMOSTAT_FILENAME),
            ('GET', TEMPERATURE_GIST, THERMOSTAT_FILENAME),
            ('PATCH', DIAGNOSTICS_GIST, DIAGNOSTICS_FILENAME),
            ('GET', DIAGNOSTICS_GIST, DIAGNOSTICS_FILENAME),
        ])
        self.assertTrue(self.old_monitor._publication_suspended)
        self.assertFalse(monitor._publication_suspended)

    def test_final_proof_get_callback_cannot_run_either_monitor(self):
        self.stage()
        candidate = self.launches[-1][1]
        callback_results = []

        def callback():
            before = len(self.events)
            results = []
            for instance in (self.old_monitor, candidate):
                results.append((instance.poll(), instance.step(10, 60)))
            callback_results.append((results, len(self.events) - before))

        self.publisher.transport.after_diagnostics_get = callback
        self.assertTrue(self.finish(2, 'trial-marker-2'))
        self.assertEqual(callback_results, [([(None, None), (None, None)], 0)])
        self.assertTrue(self.old_monitor._publication_suspended)
        self.assertFalse(candidate._publication_suspended)
        self.assertIs(self.current_monitor, candidate)

    def test_postcommit_resume_failure_is_recovery_required_not_rollback(self):
        self.stage()
        candidate = self.launches[-1][1]
        self.reporter.after_confirmed_selection = lambda *_: False
        self.assertTrue(self.finish(2, 'trial-marker-2'))
        self.assertIs(self.current_monitor, candidate)
        self.assertTrue(self.recovery_required)
        self.assertTrue(self.old_monitor._publication_suspended)
        self.assertTrue(candidate._publication_suspended)
        self.assertEqual(self.state.state['applied_id'], 2)

    def test_poll_and_step_are_fenced_until_durable_outcome(self):
        self.stage()
        monitor = self.launches[-1][1]
        for instance in (self.old_monitor, monitor):
            sequence = instance.sequence
            self.assertIsNone(instance.poll())
            self.assertIsNone(instance.step(10, 60))
            self.assertEqual(instance.sequence, sequence)
        self.assertEqual(self.events, [])
        self.assertTrue(self.finish(2, 'trial-marker-2'))

    def test_bad_request_stale_sample_or_readback_never_promotes(self):
        for mode in ('wrong_marker', 'get_mismatch', 'stale_sample'):
            with self.subTest(mode=mode):
                self.tearDown()
                self.setUp()
                self.stage()
                monitor = self.launches[-1][1]
                if mode == 'get_mismatch':
                    self.publisher.transport.get_mismatch = True
                    marker = 'trial-marker-2'
                elif mode == 'stale_sample':
                    stale_sample = monitor.take_trial_sample()
                    monitor.take_trial_sample()
                    monitor.take_trial_sample = lambda: stale_sample
                    marker = 'trial-marker-2'
                else:
                    marker = 'wrong-marker'
                self.assertFalse(self.fixed.run_operation(
                    'firmware', lambda: self.firmware.trial_ok(2, marker, True)))
                self.assertEqual(self.state.state['phase'], 'trial_entered')
                self.assertEqual(self.state.state['applied_id'], 1)
                # Caller owns explicit suppression and fallback; reporter never promotes.
                self.fail_and_restore_old_monitor()
                self.assertEqual(self.state.state['failed_high_water'], 2)
                if mode in ('wrong_marker', 'stale_sample'):
                    self.assertEqual(self.events, [])
                else:
                    self.assertEqual([event[0] for event in self.events], ['PATCH', 'GET'])

    def test_failed_trial_binding_retires_for_next_durable_trial(self):
        self.stage(2)
        failed_monitor = self.launches[-1][1]
        self.publisher.transport.get_mismatch = True
        self.assertFalse(self.finish(2, 'trial-marker-2'))
        self.fail_and_restore_old_monitor()
        self.assertTrue(failed_monitor._publication_suspended)

        # A new durable trial may bind a new monitor; the failed monitor remains
        # fenced and cannot supply proof for the new release.
        self.publisher.transport.get_mismatch = False
        self.events.clear()
        self.stage(3)
        current_monitor = self.launches[-1][1]
        self.assertEqual(self.launches[-1][0], 'B')
        self.assertTrue(failed_monitor._publication_suspended)
        self.assertFalse(self.reporter(2, 'trial-marker-2'))
        self.assertTrue(self.finish(3, 'trial-marker-3'))
        self.assertEqual([event[0:3] for event in self.events], [
            ('PATCH', TEMPERATURE_GIST, THERMOSTAT_FILENAME),
            ('GET', TEMPERATURE_GIST, THERMOSTAT_FILENAME),
            ('PATCH', DIAGNOSTICS_GIST, DIAGNOSTICS_FILENAME),
            ('GET', DIAGNOSTICS_GIST, DIAGNOSTICS_FILENAME),
        ])
        self.assertEqual(self.state.state['applied_slot'], 'B')
        self.assertEqual(self.state.state['applied_id'], 3)
        self.assertEqual(self.state.state['retained_slot'], 'A')
        self.assertEqual(self.state.state['retained_id'], 1)
        self.assertTrue(self.old_monitor._publication_suspended)
        self.assertTrue(failed_monitor._publication_suspended)
        self.assertFalse(current_monitor._publication_suspended)

    def test_competing_monitor_cannot_displace_active_trial_binding(self):
        self.stage(2)
        incumbent = self.launches[-1][1]
        binding = self.reporter._binding
        competitor = Monitor(Sensor(), self.publisher, self.clock,
                             'competing-boot-2', 'device-ref', 'pico-2')
        self.assertFalse(self.reporter.bind_launch(
            'B', 2, 'trial-marker-2', competitor, self.firmware._verify_slot,
            self.registered_gist_ids))
        self.assertIs(self.reporter._binding, binding)
        self.assertTrue(competitor._publication_suspended)
        self.assertTrue(incumbent._publication_suspended)
        self.assertTrue(self.finish(2, 'trial-marker-2'))
        self.assertFalse(incumbent._publication_suspended)
        self.assertTrue(competitor._publication_suspended)

    def test_wrong_boot_or_replaced_publisher_rejected_before_patch(self):
        self.stage()
        monitor = self.launches[-1][1]
        monitor.diagnostics['boot_id'] = 'other-boot'
        self.assertFalse(self.reporter(2, 'trial-marker-2'))
        self.assertEqual(self.events, [])
        monitor.diagnostics['boot_id'] = monitor.boot_id
        monitor.publisher = self.make_publisher()
        self.assertFalse(self.reporter(2, 'trial-marker-2'))
        self.assertEqual(self.events, [])
        self.fail_and_restore_old_monitor()

    def test_patch_exception_is_redacted_and_never_claims_proof(self):
        self.stage()
        self.publisher.transport.patch_error = 'SECRET_TOKEN_OR_RESPONSE_BODY'
        result = self.reporter(2, 'trial-marker-2')
        self.assertIs(result, False)
        self.assertNotIn('SECRET_TOKEN_OR_RESPONSE_BODY', repr(result))
        self.assertEqual(self.events, [])
        self.fail_and_restore_old_monitor()

    def test_deadline_and_wrap_safe_sampling(self):
        self.stage()
        self.clock.now += 285000
        self.assertFalse(self.finish(2, 'trial-marker-2'))
        self.fail_and_restore_old_monitor()

        self.tearDown()
        self.setUp()
        modulus = 2 ** 30
        self.clock = Clock(2 ** 30 - 5, modulus=modulus)
        # Existing model/report callbacks are rebound to the deterministic wrapped clock.
        self.state._ticks_ms, self.state._ticks_diff = self.clock.ticks_ms, self.clock.ticks_diff
        self.reporter = FirmwareTrialReporter(self.state, self.clock.ticks_ms, self.clock.ticks_diff)
        self.firmware._ticks_ms, self.firmware._ticks_diff = self.clock.ticks_ms, self.clock.ticks_diff
        self.firmware._report_trial_ok = self.reporter
        self.old_monitor.clock = self.clock
        self.stage()
        self.clock.now = modulus + 2
        self.assertTrue(self.finish(2, 'trial-marker-2'))

        self.tearDown()
        self.setUp()
        self.stage()
        self.clock.now = self.state.trial_started + 300000
        self.assertFalse(self.finish(2, 'trial-marker-2'))
        self.fail_and_restore_old_monitor()

    def test_bad_marker_is_not_bound_and_timeout_fails_closed(self):
        self.current_monitor.suspend_publication()
        raw, sig = build_candidate(2, 'v1.29.0', ASSETS, self.private)
        self.fixed.run_operation('firmware', lambda: self.firmware.admit_and_stage(
            raw, sig, 'pico-2', 'unsafe/marker'))
        self.assertFalse(self.assert_binding)
        self.assertFalse(self.reporter(2, 'unsafe/marker'))
        self.fail_and_restore_old_monitor()

        self.stage(3)
        self.clock.now += 300000
        self.assertFalse(self.finish(3, 'trial-marker-3'))
        self.assertEqual(self.state.state['applied_id'], 1)
        self.assertEqual(self.state.state['failed_high_water'], 3)
        self.assertTrue(self.old_monitor._publication_suspended)
        self.fail_and_restore_old_monitor()

    def test_unregistered_publisher_destination_rejects_binding_before_patch(self):
        self.registered_gist_ids[THERMOSTAT_FILENAME] = 'c' * 32
        raw, sig = build_candidate(2, 'v1.29.0', ASSETS, self.private)
        self.current_monitor.suspend_publication()
        self.fixed.run_operation('firmware', lambda: self.firmware.admit_and_stage(
            raw, sig, 'pico-2', 'trial-marker-2'))
        self.assertFalse(self.assert_binding)
        self.assertEqual(self.events, [])
        self.fail_and_restore_old_monitor()

    def test_two_successive_signed_updates_alternate_slots(self):
        self.stage(2)
        first = self.launches[-1][1]
        first_marker = first.take_trial_sample().marker
        self.assertEqual(first.boot_id, 'candidate-boot-2')
        self.assertTrue(self.finish(2, 'trial-marker-2'))
        self.assertTrue(first._publication_suspended is False)
        self.stage(3)
        second = self.launches[-1][1]
        self.assertTrue(first._publication_suspended)
        second_marker = second.take_trial_sample().marker
        self.assertNotEqual(first.boot_id, second.boot_id)
        self.assertNotEqual(first_marker, second_marker)
        self.assertEqual(self.launches[-1][0], 'A')
        self.assertTrue(self.finish(3, 'trial-marker-3'))
        self.assertEqual(self.state.state['applied_slot'], 'A')
        self.assertEqual(self.state.state['retained_slot'], 'B')

    def test_candidate_launch_rejection_suppresses_then_restores_one_monitor(self):
        self.current_monitor.suspend_publication()
        self.firmware._launch = lambda slot: (_ for _ in ()).throw(RuntimeError('launch failed'))
        raw, sig = build_candidate(2, 'v1.29.0', ASSETS, self.private)
        from firmware.pico.fixed_supervisor import FixedSupervisorError
        with self.assertRaises(FixedSupervisorError):
            self.fixed.run_operation('firmware', lambda: self.firmware.admit_and_stage(
                raw, sig, 'pico-2', 'trial-marker-2'))
        self.assertTrue(self.old_monitor._publication_suspended)
        self.assertEqual(self.launches, [])
        self.fail_and_restore_old_monitor()
        self.assertFalse(self.old_monitor._publication_suspended)
        self.assertIs(self.current_monitor, self.old_monitor)

    def test_invalid_ambiguous_metadata_commit_keeps_both_monitors_fenced(self):
        self.stage()
        candidate = self.launches[-1][1]
        original = self.state.confirm_trial_ok

        def ambiguous(*args):
            self.store._invalidate()
            from firmware.pico.update_state import StateWriteError
            raise StateWriteError('ambiguous private storage detail')

        self.state.confirm_trial_ok = ambiguous
        with self.assertRaises(Exception):
            self.finish(2, 'trial-marker-2')
        self.assertTrue(self.old_monitor._publication_suspended)
        self.assertTrue(candidate._publication_suspended)
        self.assertIs(self.current_monitor, self.old_monitor)
        self.state.confirm_trial_ok = original

    def test_ambiguous_metadata_promotion_never_claims_applied(self):
        self.stage()
        original = self.state.confirm_trial_ok

        def ambiguous(*args):
            self.store._invalidate()
            from firmware.pico.update_state import StateWriteError
            raise StateWriteError('ambiguous private storage detail')

        self.state.confirm_trial_ok = ambiguous
        with self.assertRaises(Exception):
            self.finish(2, 'trial-marker-2')
        self.assertIsNone(self.store.state)
        self.assertEqual(self.events[0][0:3], ('PATCH', TEMPERATURE_GIST, THERMOSTAT_FILENAME))
        self.state.confirm_trial_ok = original


if __name__ == '__main__':
    unittest.main()
