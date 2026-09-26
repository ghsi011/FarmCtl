"""Pure, host-testable telemetry formatting and diagnostic state."""

THERMOSTAT_FILENAME = 'thermostat.txt'
DIAGNOSTICS_FILENAME = 'diagnostics.json'
HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000
MAX_EVENTS = 100
MIN_CELSIUS = -55.0
MAX_CELSIUS = 125.0


def format_temperature(celsius, boot_id, sequence):
    """Return a Celsius-first payload that changes even for constant readings."""
    celsius = _validated_celsius(celsius)
    return '%.2f°C\nSample: %s:%d' % (celsius, boot_id, sequence)


def temperature_gist_payload(celsius, boot_id, sequence):
    return {
        'files': {
            THERMOSTAT_FILENAME: {
                'content': format_temperature(celsius, boot_id, sequence),
            },
        },
    }


def new_diagnostics(boot_id, device_ref, firmware_version):
    if not _safe_identifier(boot_id, 64):
        raise ValueError('boot_id must be a non-empty safe identifier of at most 64 characters')
    if not _safe_identifier(device_ref, 64):
        raise ValueError('device_ref must be a non-empty safe identifier of at most 64 characters')
    if not isinstance(firmware_version, str) or not firmware_version or len(firmware_version) > 32:
        raise ValueError('firmware_version must be a non-empty string of at most 32 characters')
    return {
        'schema_version': 1,
        'device_ref': device_ref,
        'boot_id': boot_id,
        'heartbeat_seq': 0,
        'firmware': {'running': firmware_version},
        'sensor': {
            'state': 'unknown',
            'consecutive_failures': 0,
            'last_sample_ref': None,
        },
        'reported_at': None,
        'configuration': {'applied_id': None, 'last_attempt': None},
        'events': [],
        '_event_seq': 0,
    }


def _event(snapshot, code, at_ms, uptime_s=None):
    events = snapshot['events']
    if events and events[-1]['code'] == code:
        events[-1]['count'] += 1
        events[-1]['occurred_at'] = None
        events[-1]['uptime_s'] = uptime_s if uptime_s is not None else at_ms // 1000
        return
    snapshot['_event_seq'] += 1
    event_id = '%s:%d' % (snapshot['boot_id'], snapshot['_event_seq'])
    if len(event_id) > 128:
        raise ValueError('event id exceeds 128 characters')
    events.append({
        'id': event_id,
        'code': code,
        'count': 1,
        'occurred_at': None,
        'uptime_s': uptime_s if uptime_s is not None else at_ms // 1000,
    })
    if len(events) > MAX_EVENTS:
        del events[0]


def record_sample(snapshot, celsius, boot_id, sequence, at_ms, uptime_s=None):
    """Record a valid fresh sensor read, not a successful publication."""
    celsius = _validated_celsius(celsius)
    old_state = snapshot['sensor']['state']
    snapshot['sensor']['state'] = 'ok'
    snapshot['sensor']['consecutive_failures'] = 0
    if old_state != 'ok':
        _event(snapshot, 'sensor_recovered', at_ms, uptime_s)
    return temperature_gist_payload(celsius, boot_id, sequence)


def record_temperature_published(snapshot, boot_id, sequence):
    snapshot['sensor']['last_sample_ref'] = '%s:%d' % (boot_id, sequence)


def record_failure(snapshot, at_ms, uptime_s=None):
    sensor = snapshot['sensor']
    sensor['consecutive_failures'] += 1
    if sensor['state'] != 'error':
        sensor['state'] = 'error'
    _event(snapshot, 'sensor_failed', at_ms, uptime_s)
    # Deliberately no temperature publication: do not republish the old value.
    return None


def record_temperature_publish_failure(snapshot, at_ms, uptime_s=None):
    _event(snapshot, 'temperature_publish_failed', at_ms, uptime_s)


def should_publish_diagnostics(snapshot, now_ms, last_report_ms, ticks_diff=None):
    if last_report_ms is None:
        return True
    elapsed = ticks_diff(now_ms, last_report_ms) if ticks_diff else now_ms - last_report_ms
    return elapsed >= HEARTBEAT_INTERVAL_MS


def _validated_celsius(value):
    import math
    if isinstance(value, bool):
        raise ValueError('invalid Celsius sample')
    try:
        value = float(value)
    except (TypeError, ValueError):
        raise ValueError('invalid Celsius sample')
    if not math.isfinite(value) or value < MIN_CELSIUS or value > MAX_CELSIUS:
        raise ValueError('invalid Celsius sample')
    return value


def _safe_identifier(value, maximum):
    if not isinstance(value, str) or not value or len(value) > maximum:
        return False
    return all(('a' <= character <= 'z') or ('A' <= character <= 'Z') or
               ('0' <= character <= '9') or character in '-_.' for character in value)


def diagnostics_payload(snapshot):
    """Return an independent snapshot; it contains no sensor value or secrets."""
    safe_snapshot = dict(snapshot)
    safe_snapshot.pop('_event_seq', None)
    return {'files': {DIAGNOSTICS_FILENAME: {'content': _json_dumps(safe_snapshot)}}}


def _json_dumps(value):
    # MicroPython-compatible JSON entry point; imported lazily for simple host use.
    import json
    return json.dumps(value, separators=(',', ':'))
