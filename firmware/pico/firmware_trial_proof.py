"""Host-only adapter proving fresh candidate telemetry before trial promotion.

This module is deliberately not a firmware entrypoint or launcher. A trusted
caller must bind it only after FirmwareSupervisor has persisted trial_entered
and has arranged a separately-created candidate monitor.
"""

if globals().get('__package__'):
    from .gist_publisher import GistPublisher, DIAGNOSTICS_FILENAME, THERMOSTAT_FILENAME
    from .telemetry import diagnostics_payload
else:  # MicroPython imports trusted supervisor modules from a flat sys.path.
    from gist_publisher import GistPublisher, DIAGNOSTICS_FILENAME, THERMOSTAT_FILENAME
    from telemetry import diagnostics_payload


_MAX_TRIAL_MS = 300000
_FINALIZATION_MARGIN_MS = 15000


class FirmwareTrialReporter:
    """Callable trial reporter; returns literal True only for confirmed proof."""

    def __init__(self, update_state, ticks_ms, ticks_diff):
        if not callable(ticks_ms) or not callable(ticks_diff):
            raise ValueError('trial clock callbacks are required')
        self._state = update_state
        self._ticks_ms = ticks_ms
        self._ticks_diff = ticks_diff
        self._binding = None
        self._proof_active = False

    def bind_launch(self, slot, release_id, marker, newly_created_monitor,
                    verify_slot, expected_gist_ids):
        """Bind an already-entered trial to a fresh monitor and verified slot.

        The launcher owns proving that this monitor was freshly constructed for
        its launch callback. This method independently requires its boot identity,
        diagnostics, publisher, state and signed slot to agree.
        """
        monitor = newly_created_monitor
        if monitor is None:
            return False
        try:
            # Fence the supplied monitor before inspecting any caller-controlled
            # state or invoking the slot verifier. A failed bind must never leave
            # a candidate eligible for ordinary publication.
            if monitor.suspend_publication() is not True:
                return False
        except Exception:
            return False

        if self._binding is not None and monitor is not self._binding['monitor']:
            binding = self._binding
            if self._binding_trial_was_retired(binding):
                # The durable trial changed (for example fail_trial rolled it
                # back). Retire its authorization, but leave its monitor fenced.
                self._binding = None
            else:
                # A competing monitor cannot displace a binding for the same
                # active trial. It was fenced above; retain the original binding.
                return False

        try:
            state = self._state.state
            started = self._state.trial_started
            if (state['phase'] != 'trial_entered' or type(release_id) is not int
                    or state['pending_slot'] != slot
                    or state['pending_id'] != release_id
                    or state['trial_marker'] != marker
                    or type(started) is not int or not _safe_marker(marker)):
                return False
            if (slot not in ('A', 'B') or not callable(verify_slot)
                    or not _valid_gist_ids(expected_gist_ids)):
                return False
            candidate = verify_slot(slot, release_id)
            if getattr(candidate, 'release_id', None) != release_id:
                return False
            publisher = getattr(monitor, 'publisher', None)
            diagnostics = getattr(monitor, 'diagnostics', None)
            boot_id = getattr(monitor, 'boot_id', None)
            if (monitor is None or publisher is None or not isinstance(diagnostics, dict)
                    or not _safe_identifier(boot_id, 64)
                    or diagnostics.get('boot_id') != boot_id
                    or diagnostics.get('firmware', {}).get('running') != 'pico-' + str(release_id)
                    or not _is_publisher(publisher)
                    or publisher.gist_ids != expected_gist_ids):
                return False
            now = self._ticks_ms()
            elapsed = self._ticks_diff(now, started)
            if (type(now) is not int or type(elapsed) is not int or elapsed < 0
                    or elapsed >= _MAX_TRIAL_MS - _FINALIZATION_MARGIN_MS):
                return False
            self._binding = {
                'state_object': self._state,
                'store_object': self._state.store,
                'sequence': self._state.store.sequence,
                'started': started,
                'slot': slot,
                'release_id': release_id,
                'marker': marker,
                'monitor': monitor,
                'boot_id': boot_id,
                'initial_sequence': monitor.sequence,
                'publisher': publisher,
                'gist_ids': dict(publisher.gist_ids),
                'expected_gist_ids': dict(expected_gist_ids),
                'candidate': candidate,
                'verify_slot': verify_slot,
                'launch_ms': now,
            }
            return True
        except Exception:
            return False

    def _binding_trial_was_retired(self, binding):
        """Return true only after durable metadata moved away from this trial."""
        try:
            if (self._state is not binding['state_object']
                    or self._state.store is not binding['store_object']):
                return False
            sequence = self._state.store.sequence
            state = self._state.state
            started = self._state.trial_started
            same_trial = (
                state['phase'] == 'trial_entered'
                and state['pending_slot'] == binding['slot']
                and state['pending_id'] == binding['release_id']
                and state['trial_marker'] == binding['marker']
                and started == binding['started']
            )
            # A changed marker by itself is not evidence of a new durable
            # lifecycle: require the store sequence to have advanced as well.
            return (type(sequence) is int and sequence != binding['sequence']
                    and not same_trial)
        except Exception:
            return False

    def __call__(self, release_id, marker):
        """Publish and read back both correlated files, without promoting state."""
        if self._proof_active:
            return False
        self._proof_active = True
        try:
            binding = self._binding
            if binding is None or not self._binding_is_current(binding, release_id, marker):
                return False
            monitor = binding['monitor']
            sample = monitor.take_trial_sample()
            if sample is None or not self._sample_is_fresh(binding, sample):
                return False

            publisher = binding['publisher']
            temperature_gist = binding['gist_ids'][THERMOSTAT_FILENAME]
            if publisher.patch_exact_for_trial(THERMOSTAT_FILENAME, sample.content) != sample.content:
                return False
            if publisher.confirm_file(temperature_gist, THERMOSTAT_FILENAME,
                                      sample.content) is not True:
                return False
            if not self._binding_is_current(binding, release_id, marker):
                return False
            if monitor.record_trial_sample_published(sample) is not True:
                return False

            # Monitor publication is fenced, so copy only the bounded mutable
            # diagnostic containers this proof changes; avoid deepcopy on device.
            snapshot = dict(monitor.diagnostics)
            snapshot['firmware'] = dict(monitor.diagnostics['firmware'])
            snapshot['sensor'] = dict(monitor.diagnostics['sensor'])
            snapshot['events'] = [dict(event) for event in monitor.diagnostics['events']]
            firmware = snapshot['firmware']
            firmware['running'] = 'pico-' + str(release_id)
            old_id = self._state.state['applied_id']
            firmware['retained_good'] = 'pico-' + str(old_id)
            firmware['last_attempt'] = {
                'release_id': release_id, 'trial_marker': marker,
                'state': 'trial', 'reason': None,
            }
            snapshot['sensor']['last_sample_ref'] = sample.marker
            snapshot['heartbeat_seq'] = max(snapshot.get('heartbeat_seq', 0), 1) + 1
            diagnostics_content = diagnostics_payload(snapshot)['files'][DIAGNOSTICS_FILENAME]['content']
            diagnostics_gist = binding['gist_ids'][DIAGNOSTICS_FILENAME]
            if publisher.patch_exact_for_trial(DIAGNOSTICS_FILENAME,
                                               diagnostics_content) != diagnostics_content:
                return False
            if publisher.confirm_file(diagnostics_gist, DIAGNOSTICS_FILENAME,
                                      diagnostics_content) is not True:
                return False
            # Only acknowledge this heartbeat locally after the exact diagnostics
            # content has been confirmed by readback. Keep the live state aligned
            # with the durable report so the next ordinary report advances it.
            monitor.diagnostics['heartbeat_seq'] = max(
                monitor.diagnostics.get('heartbeat_seq', 0), snapshot['heartbeat_seq'])
            if not self._binding_is_current(binding, release_id, marker):
                return False
            candidate = binding['verify_slot'](binding['slot'], release_id)
            if candidate != binding['candidate']:
                return False
            if not self._binding_is_current(binding, release_id, marker):
                return False
            return True
        except Exception:
            # Do not leak transport, storage, or credential-bearing exceptions.
            return False
        finally:
            self._proof_active = False

    def after_confirmed_selection(self, release_id, marker):
        """Update committed state locally and resume after durable promotion.

        This post-commit hook cannot roll back the durable selection. The
        coordinator must call it only after trial_ok returned literal True. It
        deliberately performs no network I/O; the ordinary monitor can publish
        the applied state on a later scheduler turn.
        """
        binding = self._binding
        if binding is None:
            return False
        try:
            state = self._state.state
            monitor = binding['monitor']
            if (state['phase'] is not None or state['applied_id'] != release_id
                    or binding['release_id'] != release_id or binding['marker'] != marker
                    or monitor.publisher is not binding['publisher']):
                return False
            retained_good = 'pico-' + str(state['retained_id'])
        except Exception:
            return False
        try:
            firmware = monitor.diagnostics['firmware']
            firmware['retained_good'] = retained_good
            firmware['last_attempt'] = {
                'release_id': release_id, 'trial_marker': marker,
                'state': 'applied', 'reason': None,
            }
        except Exception:
            return False
        try:
            monitor.resume_publication()
        except Exception:
            return False
        if self._binding is binding:
            self._binding = None
        return True

    def _binding_is_current(self, binding, release_id, marker):
        try:
            state = self._state.state
            elapsed = self._ticks_diff(self._ticks_ms(), binding['started'])
            monitor = binding['monitor']
            return (
                self._state is binding['state_object']
                and self._state.store is binding['store_object']
                and self._state.store.sequence == binding['sequence']
                and self._state.trial_started == binding['started']
                and state['phase'] == 'trial_entered'
                and state['pending_slot'] == binding['slot']
                and state['pending_id'] == binding['release_id'] == release_id
                and state['trial_marker'] == binding['marker'] == marker
                and _safe_marker(marker)
                and type(elapsed) is int
                and 0 <= elapsed < _MAX_TRIAL_MS - _FINALIZATION_MARGIN_MS
                and monitor is binding['monitor']
                and monitor.publisher is binding['publisher']
                and monitor.boot_id == binding['boot_id']
                and monitor.publisher.gist_ids == binding['gist_ids']
                and monitor.publisher.gist_ids == binding['expected_gist_ids']
                and monitor.diagnostics.get('boot_id') == binding['boot_id']
                and monitor.diagnostics.get('firmware', {}).get('running')
                    == 'pico-' + str(release_id)
            )
        except Exception:
            return False

    def _sample_is_fresh(self, binding, sample):
        try:
            monitor = binding['monitor']
            start_after_trial = self._ticks_diff(sample.start_ms, binding['started'])
            start_after_launch = self._ticks_diff(sample.start_ms, binding['launch_ms'])
            elapsed = self._ticks_diff(sample.completed_ms, sample.start_ms)
            return (
                sample.boot_id == binding['boot_id']
                and monitor.diagnostics.get('boot_id') == binding['boot_id']
                and sample.marker == '%s:%d' % (binding['boot_id'], sample.sequence)
                and type(sample.sequence) is int
                and sample.sequence > binding['initial_sequence']
                and sample.sequence == monitor.sequence
                and start_after_trial >= 0 and start_after_launch >= 0
                and type(elapsed) is int and 0 <= elapsed <= 5000
                and self._ticks_diff(sample.completed_ms, binding['started'])
                    < _MAX_TRIAL_MS - _FINALIZATION_MARGIN_MS
                and sample.content.endswith('\nSample: ' + sample.marker)
            )
        except Exception:
            return False


def _safe_marker(value):
    return (isinstance(value, str) and 0 < len(value) <= 128 and all(
        ('a' <= character <= 'z') or ('A' <= character <= 'Z')
        or ('0' <= character <= '9') or character in '_.:-'
        for character in value))


def _safe_identifier(value, maximum):
    return isinstance(value, str) and 0 < len(value) <= maximum and all(
        (('a' <= character <= 'z') or ('A' <= character <= 'Z')
         or ('0' <= character <= '9') or character in '-_.')
        for character in value)


def _valid_gist_ids(gist_ids):
    return (isinstance(gist_ids, dict)
            and set(gist_ids) == {THERMOSTAT_FILENAME, DIAGNOSTICS_FILENAME}
            and all(_is_hex_identifier(value) for value in gist_ids.values())
            and gist_ids[THERMOSTAT_FILENAME].lower()
                != gist_ids[DIAGNOSTICS_FILENAME].lower())


def _is_hex_identifier(value):
    return (isinstance(value, str) and len(value) == 32 and all(
        character in '0123456789abcdefABCDEF' for character in value))


def _is_publisher(publisher):
    return (isinstance(publisher, GistPublisher)
            and isinstance(getattr(publisher, 'gist_ids', None), dict)
            and set(publisher.gist_ids) == {THERMOSTAT_FILENAME, DIAGNOSTICS_FILENAME}
            and callable(getattr(publisher, 'patch_exact_for_trial', None))
            and callable(getattr(publisher, 'confirm_file', None)))
