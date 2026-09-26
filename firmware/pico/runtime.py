"""Small hardware adapter. Network transport is intentionally injected."""

from collections import namedtuple

from telemetry import (
    diagnostics_payload,
    new_diagnostics,
    record_failure,
    record_sample,
    record_temperature_published,
    record_temperature_publish_failure,
    should_publish_diagnostics,
)


TrialSample = namedtuple(
    'TrialSample',
    ('content', 'boot_id', 'sequence', 'start_ms', 'completed_ms', 'marker'),
)
TRIAL_SAMPLE_MAX_ELAPSED_MS = 5000


class Monitor:
    def __init__(self, sensor, publisher, clock, boot_id, device_ref,
                 firmware_version):
        self.sensor = sensor
        self.publisher = publisher
        self.clock = clock
        self.boot_id = boot_id
        self.sequence = 0
        self.diagnostics = new_diagnostics(boot_id, device_ref, firmware_version)
        self.last_report_ms = None
        self._last_clock_ms = None
        self._uptime_ms = 0
        self._last_sample_attempt_ms = None
        self._last_temperature_published_ms = None
        self._last_publication_attempt_ms = None
        self._last_step_ms = None
        self._publication_suspended = False
        self._normal_publication_active = False

    def suspend_publication(self):
        """Block ordinary poll/step work unless one is already in progress."""
        if self._normal_publication_active:
            return False
        self._publication_suspended = True
        return True

    def resume_publication(self):
        """Resume ordinary poll/step work after an explicit coordinator signal."""
        self._publication_suspended = False

    def replace_publisher(self, new_publisher):
        """Install a publisher after its configuration has been durably promoted."""
        try:
            if new_publisher is self.publisher:
                raise ValueError
            if (not callable(getattr(new_publisher, 'publish_temperature', None)) or
                    not callable(getattr(new_publisher, 'publish_diagnostics', None)) or
                    not callable(getattr(new_publisher, 'close', None))):
                raise ValueError
            old_close = getattr(self.publisher, 'close', None)
            if not callable(old_close):
                raise ValueError
        except Exception:
            raise ValueError('invalid publisher replacement') from None

        self.publisher = new_publisher
        try:
            old_close()
        except Exception:
            # The replacement remains active: configuration promotion already happened.
            raise RuntimeError('previous publisher could not be closed') from None

    def poll(self):
        if self._publication_suspended or self._normal_publication_active:
            return None
        self._normal_publication_active = True
        try:
            return self._poll_active()
        finally:
            self._normal_publication_active = False

    def _poll_active(self):
        now_ms = self.clock.ticks_ms()
        self._advance_uptime(now_ms)
        sampled, payload, previous_state = self._sample(now_ms)
        if not sampled:
            self._publish_diagnostics_if_due(
                now_ms, self.diagnostics['sensor']['state'] != previous_state
            )
            return False
        return self._publish_temperature(payload, now_ms, previous_state)

    def step(self, sample_interval_seconds, publication_interval_seconds):
        """Run one cooperative scheduler step; network and watchdog ownership stays external."""
        if self._publication_suspended or self._normal_publication_active:
            return None
        self._normal_publication_active = True
        try:
            return self._step_active(sample_interval_seconds, publication_interval_seconds)
        finally:
            self._normal_publication_active = False

    def _step_active(self, sample_interval_seconds, publication_interval_seconds):
        self._validate_intervals(sample_interval_seconds, publication_interval_seconds)
        now_ms = self.clock.ticks_ms()
        if self._last_step_ms is not None:
            elapsed = self._ticks_diff(now_ms, self._last_step_ms)
            if elapsed < 0:
                return False
        self._last_step_ms = now_ms
        self._advance_uptime(now_ms)

        sample_interval_ms = sample_interval_seconds * 1000
        publication_interval_ms = publication_interval_seconds * 1000
        sample_due = self._elapsed_at_least(
            now_ms, self._last_sample_attempt_ms, sample_interval_ms
        )
        publication_due = self._elapsed_at_least(
            now_ms, self._last_temperature_published_ms, publication_interval_ms
        )
        retry_due = self._last_publication_attempt_ms is None or self._elapsed_at_least(
            now_ms, self._last_publication_attempt_ms, sample_interval_ms
        )
        if not sample_due and not (publication_due and retry_due):
            self._publish_diagnostics_if_due(now_ms)
            return True

        self._last_sample_attempt_ms = now_ms
        if publication_due:
            self._last_publication_attempt_ms = now_ms
        sampled, payload, previous_state = self._sample(now_ms)
        if not sampled:
            self._publish_diagnostics_if_due(
                now_ms, self.diagnostics['sensor']['state'] != previous_state
            )
            return False

        if publication_due:
            return self._publish_temperature(payload, now_ms, previous_state, scheduled=True)

        self._publish_diagnostics_if_due(
            now_ms, self.diagnostics['sensor']['state'] != previous_state
        )
        return True

    def take_trial_sample(self):
        """Read fresh sensor data for trial verification without publishing it."""
        try:
            start_ms = self.clock.ticks_ms()
            if type(start_ms) is not int:
                return None
            sampled, payload, _ = self._sample(start_ms)
            if not sampled:
                return None
            completed_ms = self.clock.ticks_ms()
            if type(completed_ms) is not int:
                return None
            elapsed_ms = self._ticks_diff(completed_ms, start_ms)
            if (type(elapsed_ms) is not int or elapsed_ms < 0 or
                    elapsed_ms > TRIAL_SAMPLE_MAX_ELAPSED_MS):
                return None
            content = payload['files']['thermostat.txt']['content']
            marker = '%s:%d' % (self.boot_id, self.sequence)
            if not content.endswith('\nSample: ' + marker):
                return None
            return TrialSample(
                content, self.boot_id, self.sequence, start_ms, completed_ms, marker
            )
        except Exception:
            # Keep clock/sensor details out of logs and never return cached data.
            return None

    def record_trial_sample_published(self, sample):
        """Record only a current trial sample confirmed by the caller's readback."""
        if (not isinstance(sample, TrialSample) or sample.boot_id != self.boot_id or
                type(sample.sequence) is not int or sample.sequence != self.sequence or
                sample.marker != '%s:%d' % (self.boot_id, self.sequence) or
                not isinstance(sample.content, str) or
                not sample.content.endswith('\nSample: ' + sample.marker)):
            return False
        record_temperature_published(self.diagnostics, sample.boot_id, sample.sequence)
        return True

    @staticmethod
    def _validate_intervals(sample_interval_seconds, publication_interval_seconds):
        if (type(sample_interval_seconds) is not int or
                not 10 <= sample_interval_seconds <= 300):
            raise ValueError('sample interval must be an integer from 10 to 300 seconds')
        if (type(publication_interval_seconds) is not int or
                not 60 <= publication_interval_seconds <= 300):
            raise ValueError('publication interval must be an integer from 60 to 300 seconds')
        if sample_interval_seconds > publication_interval_seconds:
            raise ValueError('sample interval cannot exceed publication interval')

    def _elapsed_at_least(self, now_ms, previous_ms, interval_ms):
        if previous_ms is None:
            return True
        elapsed = self._ticks_diff(now_ms, previous_ms)
        return elapsed >= interval_ms

    def _sample(self, now_ms):
        previous_state = self.diagnostics['sensor']['state']
        try:
            # read_celsius must complete conversion and return a fresh sample.
            celsius = self.sensor.read_celsius()
            next_sequence = self.sequence + 1
            payload = record_sample(
                self.diagnostics, celsius, self.boot_id, next_sequence,
                now_ms, self._uptime_ms // 1000
            )
        except Exception:
            record_failure(self.diagnostics, now_ms, self._uptime_ms // 1000)
            return False, None, previous_state

        self.sequence = next_sequence
        return True, payload, previous_state

    def _publish_temperature(self, payload, now_ms, previous_state, scheduled=False):
        try:
            published = self.publisher.publish_temperature(payload)
            if published is False:
                raise OSError('temperature publication failed')
        except Exception:
            record_temperature_publish_failure(
                self.diagnostics, now_ms, self._uptime_ms // 1000
            )
            self._publish_diagnostics_if_due(now_ms, True)
            return False

        record_temperature_published(self.diagnostics, self.boot_id, self.sequence)
        if scheduled:
            self._last_temperature_published_ms = now_ms
            self._last_publication_attempt_ms = None
        self._publish_diagnostics_if_due(
            now_ms, self.diagnostics['sensor']['state'] != previous_state
        )
        return True

    def _advance_uptime(self, now_ms):
        if self._last_clock_ms is not None:
            self._uptime_ms += self._ticks_diff(now_ms, self._last_clock_ms)
        self._last_clock_ms = now_ms

    def _ticks_diff(self, current, previous):
        ticks_diff = getattr(self.clock, 'ticks_diff', None)
        if ticks_diff is not None:
            return ticks_diff(current, previous)
        return current - previous

    def _publish_diagnostics_if_due(self, now_ms, transition=False):
        if transition or should_publish_diagnostics(
            self.diagnostics, now_ms, self.last_report_ms, self._ticks_diff
        ):
            self.diagnostics['heartbeat_seq'] += 1
            try:
                published = self.publisher.publish_diagnostics(
                    diagnostics_payload(self.diagnostics)
                )
            except Exception:
                # Best effort only; never expose arbitrary transport error text.
                return
            if published is False:
                return
            self.last_report_ms = now_ms


class Ds18x20Sensor:
    """DS18X20 adapter with pin intentionally supplied by board integration."""

    def __init__(self, machine_module, onewire_module, ds18x20_module, pin_number):
        pin = machine_module.Pin(pin_number)
        self.sensor = ds18x20_module.DS18X20(onewire_module.OneWire(pin))
        self.roms = self.sensor.scan()
        if not self.roms:
            raise OSError('no temperature sensors')

    def read_celsius(self):
        import time
        self.sensor.convert_temp()
        time.sleep_ms(750)
        return self.sensor.read_temp(self.roms[0])


def github_api_transport(host, request):
    """Not-qualified HTTPS boundary; caller must inject TLS-capable request.

    The fixed API host prevents arbitrary destinations. This adapter does not
    select credentials, construct private URLs, or fall back to plain HTTP.
    TLS behavior must be qualified on the target MicroPython build before use.
    """
    if host != 'api.github.com':
        raise ValueError('only api.github.com is permitted')
    return request(host)
