"""Host-only orchestration model for fixed A/B firmware slots.

This is deliberately not an auto-runner or a production filesystem adapter.
The caller must provide isolated slot accessors and a native Ed25519 verifier.
Host tests do not establish physical filesystem/symlink isolation, TLS security,
actual diagnostics-Gist proof, watchdog behavior, or serialization with runtime
and configuration trials. Those integrations and issue #43 remain external.
Do not wire this model to boot execution until those platform boundaries are
implemented and independently qualified.
"""

if globals().get('__package__'):
    from .candidate_manifest import verify_candidate, verify_staged_assets
    from .update_state import RecoveryRequired, StateWriteError
else:  # MicroPython imports trusted supervisor modules from a flat sys.path.
    from candidate_manifest import verify_candidate, verify_staged_assets
    from update_state import RecoveryRequired, StateWriteError


class FirmwareSupervisorError(Exception):
    """A candidate could not safely be admitted or booted."""


class RecoveryRequiredError(FirmwareSupervisorError):
    """Neither retained firmware slot can be authenticated; use USB recovery."""


class _ServiceCheckpointError(FirmwareSupervisorError):
    """A watchdog/deadline checkpoint did not permit safe progress."""


class FirmwareSupervisor:
    """Coordinate authentication, slot writes, trials, and boot selection.

    ``slot_reader(slot)`` returns ``(raw_manifest, signature, asset_accessor)``;
    the accessor implements ``open_asset(relative_path)`` and ``list_assets()``.
    ``stage_writer(slot, candidate, raw_manifest, signature)`` receives only a
    signed candidate and a fixed A/B slot name. It must not redirect writes.
    ``service`` is an optional watchdog/deadline checkpoint. It is called with
    cumulative hashed bytes (or with no arguments for a no-argument callback).
    The caller owns its timing policy; this model makes no latency guarantee.
    The stage writer remains responsible for checkpointing while it writes.
    """

    def __init__(self, update_state, trusted_public_key, verifier, board, runtime,
                 slot_reader, stage_writer, launch, ticks_ms, ticks_diff,
                 report_trial_ok, service=None):
        if not isinstance(trusted_public_key, bytes) or len(trusted_public_key) != 32:
            raise ValueError('trusted verifier key must be immutable raw32 bytes')
        if not all(callable(item) for item in
                   (verifier, slot_reader, stage_writer, launch, ticks_ms,
                    ticks_diff, report_trial_ok)):
            raise ValueError('supervisor callbacks must be callable')
        self._state = update_state
        self._key = trusted_public_key
        self._verifier = verifier
        self._board = board
        self._runtime = runtime
        self._read_slot = slot_reader
        self._write_slot = stage_writer
        self._launch = launch
        self._ticks_ms = ticks_ms
        self._ticks_diff = ticks_diff
        self._report_trial_ok = report_trial_ok
        if service is not None and not callable(service):
            raise ValueError('supervisor service callback must be callable')
        self._service = service

    def _service_checkpoint(self, byte_count=0):
        if self._service is None:
            return
        try:
            result = self._service(byte_count)
            if result is False:
                raise _ServiceCheckpointError('service checkpoint declined')
        except _ServiceCheckpointError:
            raise
        except Exception:
            raise _ServiceCheckpointError('service checkpoint failed') from None

    def _authenticate(self, raw, signature, tag, applied_id=None, failed_id=None):
        return verify_candidate(raw, signature, self._key, self._board,
                                self._runtime, tag, applied_id, failed_id,
                                verifier=self._verifier)

    def _verify_slot(self, slot, expected_id=None, enforce_highwaters=False):
        if slot not in ('A', 'B') or type(expected_id) is not int or expected_id <= 0:
            raise FirmwareSupervisorError('slot must be fixed A or B')
        try:
            raw, signature, assets = self._read_slot(slot)
            state = self._state.state
            candidate = self._authenticate(
                raw, signature, 'pico-' + str(expected_id),
                state['applied_id'] if enforce_highwaters else None,
                state['failed_high_water'] if enforce_highwaters else None)
            if expected_id is not None and candidate.release_id != expected_id:
                raise FirmwareSupervisorError('slot release id mismatch')
            cancelled = [False]

            def service_hash(count):
                try:
                    self._service_checkpoint(count)
                    return True
                except _ServiceCheckpointError:
                    cancelled[0] = True
                    return False

            try:
                verified = verify_staged_assets(
                    candidate, assets, service=service_hash if self._service else None)
            except Exception:
                if cancelled[0]:
                    raise _ServiceCheckpointError('service checkpoint declined') from None
                raise
            if cancelled[0]:
                raise _ServiceCheckpointError('service checkpoint declined')
            if verified is not True:
                raise FirmwareSupervisorError('slot assets failed verification')
            return candidate
        except FirmwareSupervisorError:
            raise
        except Exception:
            raise FirmwareSupervisorError('slot could not be authenticated') from None

    def admit_and_stage(self, raw_manifest, signature, release_tag, trial_marker):
        state = self._state.state
        candidate = self._authenticate(raw_manifest, signature, release_tag,
                                       state['applied_id'], state['failed_high_water'])
        if candidate.release_id <= max(state['installed_high_water'], state['failed_high_water']):
            raise FirmwareSupervisorError('candidate is not newer than recorded high-waters')
        try:
            self._state.stage_candidate(candidate.release_id, trial_marker, True, True,
                                        trial_kind='firmware')
        except Exception:
            raise
        slot = self._state.state['pending_slot']
        try:
            self._service_checkpoint()
            self._write_slot(slot, candidate, raw_manifest, signature)
            self._service_checkpoint()
            staged = self._verify_slot(slot, candidate.release_id)
            if staged != candidate:
                raise FirmwareSupervisorError('staged candidate differs from admission')
            self._service_checkpoint()
            self._state.assets_verified_and_enter_trial(True, True)
            self._launch(slot)
        except (StateWriteError, RecoveryRequired):
            # Persistence/metadata is ambiguous. Never claim suppression.
            raise
        except Exception:
            try:
                self._state.fail_trial()
            except (StateWriteError, RecoveryRequired):
                raise FirmwareSupervisorError('failure suppression ambiguous; reload before use') from None
            raise FirmwareSupervisorError('staging failed; candidate suppressed') from None
        return slot

    def trial_ok(self, release_id, marker, confirmed):
        """Promote only a literal confirmed diagnostics success before deadline."""
        if confirmed is not True:
            return False
        state = self._state.state
        if (state['phase'] != 'trial_entered' or release_id != state['pending_id']
                or marker != state['trial_marker']):
            return False
        try:
            if self._state.tick():
                return False
            # The reporter is the integration point for checked diagnostics/Gist
            # confirmation. It must return literal True, not a truthy response.
            if self._report_trial_ok(release_id, marker) is not True:
                return False
            return self._state.confirm_trial_ok(release_id, marker, True)
        except (StateWriteError, RecoveryRequired):
            raise

    def tick(self):
        return self._state.tick()

    def fail_trial(self):
        return self._state.fail_trial()

    def boot(self):
        """Recover metadata, authenticate selected slot, then and only then launch."""
        try:
            self._state.store.load()
            self._state.recover_after_boot()
            state = self._state.state
            applied = state['applied_slot']
            try:
                self._verify_slot(applied, state['applied_id'])
                selected = applied
            except _ServiceCheckpointError:
                raise
            except FirmwareSupervisorError:
                retained = state['retained_slot']
                if retained not in ('A', 'B'):
                    raise RecoveryRequiredError('applied slot invalid and no retained slot')
                self._verify_slot(retained, state['retained_id'])
                self._state.recover_retained(retained, True)
                selected = retained
            self._launch(selected)
            return selected
        except (StateWriteError, RecoveryRequired):
            raise
        except RecoveryRequiredError:
            raise
        except Exception:
            raise RecoveryRequiredError('no authenticated firmware slot; USB recovery required') from None
