"""Explicit host/spare-only configuration promotion coordinator.

This module is intentionally not wired to an installed ``main.py`` or any
production runner. Device qualification (candidate Wi-Fi, sensor, TLS and
power-cut #43) is still required before activation is enabled anywhere.
"""

import hashlib

from config_payload import read_device_payload
from config_proof_io import CandidateProofIO, ConfigProofIOFailure
from config_stage import AppliedConfigInvalid, ConfigStageCoordinator, ConfigStageError
from config_trial import ConfigTrialStore, _ConfigProof, TRIAL_MS
from fixed_supervisor import FixedSupervisor
from telemetry import diagnostics_payload, record_config_applied, record_config_attempt


CONFIG_AUTOMATIC_PROMOTION_ENABLED = False
MAX_TRIAL_MS = 300000
FINALIZATION_MARGIN_MS = 15000


class WifiAssociationConfirmed:
    """Typed affirmative observation from the candidate Wi-Fi adapter."""
    __slots__ = ('profile_id', 'connected_at')

    def __init__(self, profile_id, connected_at):
        self.profile_id = profile_id
        self.connected_at = connected_at


class WifiAssociationFailed:
    """Typed, definite candidate association failure (not an unknown outage)."""
    __slots__ = ()


class ConfigPromotionCoordinator:
    """Run one externally invoked, deadline-bounded config promotion attempt."""

    def __init__(self, stage, owner, monitor, clock, connect_candidate,
                 restore_applied, proof_io_factory, service=None):
        if (not isinstance(stage, ConfigStageCoordinator) or
                not isinstance(owner, FixedSupervisor) or
                not isinstance(stage.store, ConfigTrialStore) or
                getattr(owner, '_config_store', None) is not stage.store or
                not callable(getattr(clock, 'ticks_ms', None)) or
                not callable(connect_candidate) or not callable(restore_applied) or
                not callable(proof_io_factory) or
                not callable(getattr(monitor, 'take_trial_sample', None)) or
                not callable(getattr(monitor, 'record_trial_sample_published', None)) or
                not callable(getattr(monitor, 'replace_publisher', None))):
            raise ValueError('promotion capabilities are not consistently bound')
        self.stage, self.store, self.owner = stage, stage.store, owner
        self.monitor, self.clock = monitor, clock
        self.connect_candidate, self.restore_applied = connect_candidate, restore_applied
        self.proof_io_factory, self.service = proof_io_factory, service
        # If durable selection succeeds but monitor installation fails before
        # taking ownership, keep the detached writer reachable for recovery.
        self._recovery_publisher = None
        self._recovery_private_client = None

    def run_once(self):
        """Explicitly promote at most one candidate; never called automatically."""
        return self.owner.run_operation('config', self._run_guarded)

    def _run_guarded(self):
        io = None
        trial = False
        old_config = None
        candidate = None
        baseline_verified = False
        fenced = self.monitor.suspend_publication()
        if not fenced:
            return {'state': 'deferred'}
        trial_started = None
        committed = False
        try:
            self._deadline_preflight()
            initial_state = self.store.state
            try:
                self._read_ref(initial_state['applied'], initial_state['applied_revision'],
                               initial_state['applied_change_id'])
            except Exception:
                raise _RecoveryRequired('applied baseline invalid') from None
            baseline_verified = True
            reference = self.stage.stage_latest()
            if reference is None:
                self.monitor.resume_publication()
                return None
            applied, candidate = self._verify_references(reference)
            old_config = applied
            applied_id = self.monitor.diagnostics['configuration'].get('applied_id')
            if applied_id is None:
                self.monitor.diagnostics['configuration']['applied_id'] = self.store.state['applied_change_id']
            elif applied_id != self.store.state['applied_change_id']:
                raise _RecoveryRequired('applied telemetry identity mismatch')
            state = self.store.state
            revision, change_id = state['revision'], state['change_id']
            self._best_effort_attempt(revision, change_id, 'received', None)
            self.store.enter_trial()
            trial = True
            trial_started = self.store.trial_started
            trial_sequence = self.store.sequence
            self._check_deadline(trial_started, reserve=True)
            self._best_effort_attempt(revision, change_id, 'trial', None, trial_started)

            observation = self._call_bounded(
                lambda remaining: self.connect_candidate(
                    candidate.device.wifi_profiles, remaining,
                    self._trial_service(trial_started)),
                trial_started, reserve=True)
            if isinstance(observation, WifiAssociationFailed):
                raise _PromotionFailure('wifi_failed')
            if not isinstance(observation, WifiAssociationConfirmed):
                raise _PromotionFailure('inconclusive')
            profile_ids = [profile.profile_id for profile in candidate.device.wifi_profiles]
            elapsed = self.store._elapsed(observation.connected_at)
            if (observation.profile_id not in profile_ids or elapsed is None or
                    elapsed < 0 or elapsed >= MAX_TRIAL_MS):
                raise _PromotionFailure('inconclusive')
            self._check_deadline(trial_started, reserve=True)

            io = self.proof_io_factory(candidate)
            if not isinstance(io, CandidateProofIO):
                raise _PromotionFailure('inconclusive')
            bound_stage_client = self.stage.private_client
            self._call_bounded(lambda remaining: io.bind_trial(
                self.store, applied, bound_stage_client),
                               trial_started, reserve=True)
            fetched = self._call_bounded(
                lambda remaining: io.read_exact_candidate(
                    candidate, service=self._trial_service(trial_started)),
                trial_started, reserve=True)
            if fetched != candidate:
                raise _PromotionFailure('invalid_config')

            sample = self._call_bounded(lambda remaining: self.monitor.take_trial_sample(),
                                        trial_started, reserve=True)
            if not _fresh_sample(sample, trial_started, self.store, self.monitor):
                raise _PromotionFailure('sensor_failed')
            content = self._call_bounded(
                lambda remaining: io.patch_exact(
                    'thermostat.txt', sample.content,
                    service=self._trial_service(trial_started)),
                trial_started, reserve=True)
            if content != sample.content:
                raise _PromotionFailure('inconclusive')
            confirmed = self._call_bounded(
                lambda remaining: io.confirm_exact(
                    'thermostat.txt', sample.content,
                    service=self._trial_service(trial_started)),
                trial_started, reserve=True)
            if confirmed is not True:
                raise _PromotionFailure('inconclusive')
            recorded = self._call_bounded(
                lambda remaining: self.monitor.record_trial_sample_published(sample),
                trial_started, reserve=True)
            if recorded is not True:
                raise _PromotionFailure('sensor_failed')

            snapshot = self.monitor.diagnostics
            _require_correlated(snapshot, state, sample)
            snapshot['heartbeat_seq'] += 1
            frozen_diagnostics = diagnostics_payload(snapshot)['files']['diagnostics.json']['content']
            patched = self._call_bounded(
                lambda remaining: io.patch_exact(
                    'diagnostics.json', frozen_diagnostics,
                    service=self._trial_service(trial_started)),
                trial_started, reserve=True)
            if patched != frozen_diagnostics:
                raise _PromotionFailure('inconclusive')
            diagnostic_readback = self._call_bounded(
                lambda remaining: io.confirm_exact(
                    'diagnostics.json', frozen_diagnostics,
                    service=self._trial_service(trial_started)),
                trial_started, reserve=True)
            if diagnostic_readback is not True:
                raise _PromotionFailure('inconclusive')

            self._assert_trial_unchanged(reference, trial_started, trial_sequence, io)
            if self.stage.private_client is not bound_stage_client:
                raise _PromotionFailure('inconclusive')
            self._check_deadline(trial_started, reserve=True)
            committed = self.store.expire_or_confirm(self.clock.ticks_ms(), _ConfigProof(self.store))
            if committed is not True:
                raise _PromotionFailure('inconclusive')
            committed = True
            trial = False

            # From durable selection onward never rollback or use the old writer.
            record_config_applied(snapshot, revision, change_id)
            new_publisher = None
            candidate_client = None
            publication_ready = True
            try:
                new_publisher, candidate_client = io.detach_after_commit(self.store)
                self._recovery_publisher = new_publisher
                self._recovery_private_client = candidate_client
                if self.stage.private_client is not bound_stage_client:
                    raise ValueError('stage reader changed after proof')
                self.stage.private_client = candidate_client
                self._recovery_private_client = None
                cleanup_ok = self._retire_private_reader(bound_stage_client)
                self.monitor.replace_publisher(new_publisher)
                self._recovery_publisher = None
            except Exception:
                if (self.stage.private_client is candidate_client and
                        self.monitor.publisher is new_publisher):
                    self._recovery_private_client = None
                    self._recovery_publisher = None
                    self._quarantine()
                    cleanup_ok = False
                    publication_ready = False
                else:
                    self._quarantine()
                    # Detached resources remain reachable either at their
                    # installed owner or in the recovery slots.
                    self._close_io(io)
                    return {'state': 'applied', 'recovery_required': True}
            try:
                io.close()
            except Exception:
                cleanup_ok = False
            io = None
            if not publication_ready:
                self._quarantine()
                return {'state': 'applied', 'recovery_required': True}
            try:
                report_result = self.monitor.publisher.publish_diagnostics(diagnostics_payload(snapshot))
            except Exception:
                report_result = False
            if not cleanup_ok:
                self._quarantine()
            self.monitor.resume_publication()
            result = {'state': 'applied', 'recovery_required': not cleanup_ok}
            if report_result is False:
                result['report_pending'] = True
            elapsed_after_report = self._elapsed(trial_started)
            if elapsed_after_report is None or elapsed_after_report >= MAX_TRIAL_MS:
                result['warning'] = 'committed result completed after trial deadline'
            return result
        except Exception as error:
            state = self.store.state
            if state is None or not isinstance(state, dict):
                self._quarantine()
                self._close_io(io)
                return {'state': 'recovery_required'}
            if committed:
                self._quarantine()
                self._close_io(io)
                return {'state': 'applied', 'recovery_required': True,
                        'warning': 'committed cleanup incomplete'}
            if isinstance(error, (AppliedConfigInvalid, _RecoveryRequired)):
                self._quarantine()
                self._close_io(io)
                return {'state': 'recovery_required'}
            if not trial:
                self._reject_if_staged(error)
                self._close_io(io)
                state = self.store.state
                if isinstance(state, dict) and state.get('status') == 'rejected':
                    self.monitor.resume_publication()
                    return {'state': 'rejected'}
                if (baseline_verified and isinstance(state, dict) and
                        state.get('status') in ('applied', 'ready', 'rolled_back')):
                    self.monitor.resume_publication()
                    return {'state': 'inconclusive'}
                self._quarantine()
                return {'state': 'recovery_required'}
            reason = self._reason(error)
            try:
                self.store.rollback(reason)
            except Exception:
                self._quarantine()
                self._close_io(io)
                return {'state': 'recovery_required'}
            self._close_io(io)
            try:
                state = self.store.state
                self._read_ref(state['applied'], state['applied_revision'],
                               state['applied_change_id'])
            except Exception:
                self._quarantine()
                return {'state': 'recovery_required'}
            restored = False
            try:
                restore_remaining = self._remaining(trial_started)
                result = self.restore_applied(old_config, restore_remaining,
                                              self._deadline_service(trial_started))
                restored = result is True and restore_remaining > 0
            except Exception:
                restored = False
            if not restored or not self._within_healthy_window(trial_started):
                self._quarantine()
                return {'state': 'recovery_required'}
            self._best_effort_attempt(self.store.state['revision'], self.store.state['change_id'],
                                      'rolled_back', reason)
            if not self._within_healthy_window(trial_started):
                self._quarantine()
                return {'state': 'recovery_required'}
            self.monitor.resume_publication()
            return {'state': 'rolled_back', 'reason': reason}

    def _verify_references(self, returned_reference):
        state = self.store.state
        if state.get('status') != 'staged' or state.get('candidate') != returned_reference:
            raise _PromotionFailure('invalid_config')
        applied_ref, candidate_ref = state['applied'], state['candidate']
        try:
            applied = self._read_ref(applied_ref, state['applied_revision'], state['applied_change_id'])
        except Exception:
            raise _RecoveryRequired('applied baseline invalid') from None
        candidate = self._read_ref(candidate_ref, state['revision'], state['change_id'])
        if applied.device.temperature_gist_id != candidate.device.temperature_gist_id:
            raise _PromotionFailure('invalid_config')
        return applied, candidate

    def _read_ref(self, reference, revision, change_id):
        name, count, digest = reference
        path = self.stage.payload_directory.rstrip('/') + '/' + name
        hasher, data = hashlib.sha256(), bytearray()
        with open(path, 'rb') as handle:
            while True:
                block = handle.read(1024)
                if not block:
                    break
                if len(data) + len(block) > 16384:
                    raise _PromotionFailure('invalid_config')
                data.extend(block)
                hasher.update(block)
        raw = bytes(data)
        actual = ''.join('%02x' % byte for byte in hasher.digest())
        if len(raw) != count or actual != digest:
            raise _PromotionFailure('invalid_config')
        parsed = read_device_payload(raw, self.stage.device_ref)
        if parsed.revision != revision or parsed.device.change_id != change_id:
            raise _PromotionFailure('invalid_config')
        return parsed

    def _call_bounded(self, callback, started, reserve):
        self._check_deadline(started, reserve)
        remaining = self._remaining(started)
        try:
            result = callback(remaining)
        except ConfigProofIOFailure as error:
            raise _PromotionFailure(_proof_reason(error.kind)) from None
        except _PromotionFailure:
            raise
        except Exception:
            raise _PromotionFailure('inconclusive') from None
        self._check_deadline(started, reserve)
        return result

    def _deadline_preflight(self):
        if self.store.state is None or self.store.state.get('status') not in ('ready', 'rejected', 'rolled_back', 'applied'):
            raise _PromotionFailure('inconclusive')

    def _check_deadline(self, started=None, reserve=False):
        if started is None:
            return
        elapsed = self._elapsed(started)
        limit = MAX_TRIAL_MS - (FINALIZATION_MARGIN_MS if reserve else 0)
        if elapsed is None or elapsed >= limit:
            raise _PromotionFailure('inconclusive')

    def _remaining(self, started=None):
        if started is None:
            return 0
        elapsed = self._elapsed(started)
        if elapsed is None:
            return 0
        return max(0, MAX_TRIAL_MS - elapsed)

    def _elapsed(self, started):
        try:
            now = self.clock.ticks_ms()
            ticks_diff = getattr(self.clock, 'ticks_diff', None)
            if (type(started) is not int or type(now) is not int or
                    not 0 <= started < (1 << 30) or not 0 <= now < (1 << 30) or
                    not callable(ticks_diff)):
                return None
            elapsed = ticks_diff(now, started)
        except Exception:
            return None
        if type(elapsed) is not int or not -(1 << 29) <= elapsed < (1 << 29):
            return None
        return elapsed if elapsed >= 0 else None

    def _within_healthy_window(self, started):
        elapsed = self._elapsed(started)
        return elapsed is not None and elapsed < MAX_TRIAL_MS

    def _quarantine(self):
        try:
            self.owner.quarantine_operations()
        except Exception:
            pass

    def _trial_service(self, started):
        if not callable(self.service):
            return None

        def service(*args, **kwargs):
            self._check_deadline(started, reserve=True)
            try:
                result = self.service(*args, **kwargs)
            except Exception:
                raise _PromotionFailure('inconclusive') from None
            self._check_deadline(started, reserve=True)
            return result
        return service

    def _deadline_service(self, started):
        if not callable(self.service):
            return None
        def service(*args, **kwargs):
            remaining = self._remaining(started)
            if remaining <= 0:
                raise _PromotionFailure('inconclusive')
            result = self.service(*args, **kwargs)
            self._check_deadline(started)
            return result
        return service

    def _assert_trial_unchanged(self, reference, started, sequence, io):
        state = self.store.state
        if (state is None or state.get('status') != 'trial' or
                state.get('candidate') != reference or self.store.trial_started != started or
                self.store.sequence != sequence):
            raise _PromotionFailure('inconclusive')
        binding = getattr(io, '_bound_trial', None)
        if (binding is None or len(binding) < 3 or binding[0] is not self.store or
                binding[1] != sequence or binding[2] != started):
            raise _PromotionFailure('inconclusive')
        self._check_deadline(started, reserve=True)

    def _best_effort_attempt(self, revision, change_id, status, reason, started=None):
        try:
            if started is not None:
                self._check_deadline(started, reserve=True)
            record_config_attempt(self.monitor.diagnostics, revision, change_id, status, reason)
            self.monitor.publisher.publish_diagnostics(diagnostics_payload(self.monitor.diagnostics))
            if started is not None:
                self._check_deadline(started, reserve=True)
        except Exception:
            pass

    def _reject_if_staged(self, error):
        state = self.store.state
        if isinstance(state, dict) and state.get('status') in ('received', 'staged'):
            try:
                self.store.reject(self._reason(error))
            except Exception:
                pass

    def _reason(self, error):
        if isinstance(error, _PromotionFailure):
            return error.reason
        if isinstance(error, ConfigStageError):
            return 'invalid_config'
        if isinstance(error, ConfigProofIOFailure):
            return _proof_reason(error.kind)
        return 'inconclusive'

    @staticmethod
    def _close_io(io):
        try:
            if io is not None:
                io.close()
        except Exception:
            pass

    @staticmethod
    def _retire_private_reader(client):
        """Close and scrub a superseded reader, even when close itself fails."""
        transport = getattr(client, 'transport', None)
        cleanup_ok = True
        try:
            close = getattr(transport, 'close', None)
            if callable(close):
                close()
        except Exception:
            cleanup_ok = False
        finally:
            token = getattr(transport, 'token', None)
            if isinstance(token, bytearray):
                for index in range(len(token)):
                    token[index] = 0
            if transport is not None:
                try:
                    transport._closed = True
                except Exception:
                    cleanup_ok = False
        return cleanup_ok


class _PromotionFailure(Exception):
    def __init__(self, reason):
        self.reason = reason if reason in (
            'invalid_config', 'inconclusive', 'authentication_failed',
            'destination_failed', 'wifi_failed', 'sensor_failed') else 'inconclusive'
        super().__init__(self.reason)


class _RecoveryRequired(Exception):
    pass


def _proof_reason(kind):
    return kind if kind in ('invalid_config', 'authentication_failed',
                            'destination_failed') else 'inconclusive'


def _fresh_sample(sample, started, store, monitor):
    if (sample is None or not isinstance(getattr(sample, 'content', None), str) or
            type(getattr(sample, 'sequence', None)) is not int or sample.sequence < 1 or
            not isinstance(getattr(sample, 'marker', None), str) or
            sample.boot_id != monitor.boot_id or sample.sequence != monitor.sequence or
            sample.marker != '%s:%d' % (monitor.boot_id, sample.sequence) or
            not sample.content.endswith('\nSample: ' + sample.marker)):
        return False
    elapsed = store._elapsed(sample.start_ms)
    completed = store._elapsed(sample.completed_ms)
    return (elapsed is not None and elapsed >= 0 and elapsed < MAX_TRIAL_MS and
            completed is not None and completed >= elapsed and completed < MAX_TRIAL_MS)


def _require_correlated(snapshot, state, sample):
    config = snapshot.get('configuration', {})
    attempt = config.get('last_attempt')
    if (config.get('applied_id') != state.get('applied_change_id') or
            not isinstance(attempt, dict) or attempt.get('state') != 'trial' or
            attempt.get('fleet_revision') != state.get('revision') or
            attempt.get('change_id') != state.get('change_id') or
            snapshot.get('sensor', {}).get('last_sample_ref') != sample.marker):
        raise _PromotionFailure('inconclusive')
