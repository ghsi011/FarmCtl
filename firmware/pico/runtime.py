"""Small hardware adapter. Network transport is intentionally injected."""

from telemetry import (
    diagnostics_payload,
    new_diagnostics,
    record_failure,
    record_sample,
    record_temperature_published,
    record_temperature_publish_failure,
    should_publish_diagnostics,
)


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

    def poll(self):
        now_ms = self.clock.ticks_ms()
        self._advance_uptime(now_ms)
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
            self._publish_diagnostics_if_due(
                now_ms, self.diagnostics['sensor']['state'] != previous_state
            )
            return False

        self.sequence = next_sequence
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
