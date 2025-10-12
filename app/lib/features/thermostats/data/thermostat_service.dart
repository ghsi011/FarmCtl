import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import 'thermostat_client.dart';
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
    );
    return updated;
  }
}
