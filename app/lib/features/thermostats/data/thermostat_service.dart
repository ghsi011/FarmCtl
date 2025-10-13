import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import 'thermostat_client.dart';
import 'thermostat_reading_utils.dart';
import 'thermostat_repository.dart';

class ThermostatService {
  ThermostatService({
    required ThermostatRepository repository,
    required ThermostatNetworkDataSource network,
  }) : _repository = repository,
       _network = network;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;

  Future<Thermostat> createAndTest(ThermostatDraft draft) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final result = await _network.fetchCurrent(draft.rawUrl.trim());
    final saved = await _repository.create(draft);
    await _repository.saveState(
      thermostatId: saved.id,
      status: ThermostatReadingStatus.ok,
      valueC: result.valueC,
      fetchedAt: result.fetchedAt,
      etag: result.etag,
      message: 'Fetched ${result.valueC.toStringAsFixed(1)}°C',
    );
    return saved;
  }

  Future<Thermostat> updateAndTest(
    Thermostat existing,
    ThermostatDraft draft,
  ) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final result = await _network.fetchCurrent(draft.rawUrl.trim());
    final updated = await _repository.update(existing, draft);
    await _repository.saveState(
      thermostatId: updated.id,
      status: ThermostatReadingStatus.ok,
      valueC: result.valueC,
      fetchedAt: result.fetchedAt,
      etag: result.etag,
      message: 'Fetched ${result.valueC.toStringAsFixed(1)}°C',
    );
    return updated;
  }

  Future<ThermostatRefreshResult> refresh(Thermostat thermostat) async {
    final previousState = await _repository.loadState(thermostat.id);
    try {
      final result = await _network.fetchCurrent(thermostat.rawUrl.trim());
      final value = result.valueC;
      final fetchedAt = result.fetchedAt;
      final outOfRange = isThermostatReadingOutOfRange(
        thermostat: thermostat,
        currentValue: value,
        previousState: previousState,
      );
      if (outOfRange) {
        final message = formatOutOfRangeThermostatMessage(thermostat, value);
        await _repository.saveState(
          thermostatId: thermostat.id,
          status: ThermostatReadingStatus.outOfRange,
          valueC: value,
          fetchedAt: fetchedAt,
          etag: result.etag,
          message: message,
        );
        return ThermostatRefreshResult(
          status: ThermostatReadingStatus.outOfRange,
          message: message,
          valueC: value,
          fetchedAt: fetchedAt,
        );
      }

      final message = 'Fetched ${value.toStringAsFixed(1)}°C';
      final shouldClearSnooze = previousState?.snoozedUntil != null;
      final hadSilence = previousState?.silenceUntilOk == true;
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.ok,
        valueC: value,
        fetchedAt: fetchedAt,
        etag: result.etag,
        message: message,
        setSnoozedUntil: shouldClearSnooze,
        snoozedUntil: null,
        setSilenceUntilOk: hadSilence,
        silenceUntilOk: false,
      );
      return ThermostatRefreshResult(
        status: ThermostatReadingStatus.ok,
        message: message,
        valueC: value,
        fetchedAt: fetchedAt,
      );
    } on ThermostatFetchException catch (error) {
      final now = DateTime.now().toUtc();
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: error.status,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
        etag: previousState?.etag,
        message: error.message,
      );
      return ThermostatRefreshResult(
        status: error.status,
        message: error.message,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
      );
    } catch (error) {
      final now = DateTime.now().toUtc();
      final message = 'Unexpected error: $error';
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.unknown,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
        etag: previousState?.etag,
        message: message,
      );
      return ThermostatRefreshResult(
        status: ThermostatReadingStatus.unknown,
        message: message,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
      );
    }
  }
}

class ThermostatRefreshResult {
  const ThermostatRefreshResult({
    required this.status,
    required this.message,
    this.valueC,
    required this.fetchedAt,
  });

  final ThermostatReadingStatus status;
  final String message;
  final double? valueC;
  final DateTime fetchedAt;

  bool get isSuccess =>
      status == ThermostatReadingStatus.ok ||
      status == ThermostatReadingStatus.outOfRange;
}
