/// Maps an arbitrary thrown object to a short, friendly, actionable message
/// suitable for end users. Raw exception/stack text (Dio, Drift, sockets) is
/// noise to a non-technical user and can leak internal detail, so error
/// surfaces should route through this instead of interpolating `'$error'`.
String humanizeError(Object? error) {
  if (error == null) {
    return 'Something went wrong. Please try again.';
  }
  final text = error.toString().toLowerCase();

  bool has(String needle) => text.contains(needle);

  if (has('timeout') || has('timed out')) {
    return 'The request timed out. Check your connection and try again.';
  }
  if (has('socket') ||
      has('connection') ||
      has('network') ||
      has('host lookup') ||
      has('unreachable') ||
      has('failed host')) {
    return "Couldn't reach the server. Check your connection and try again.";
  }
  if (has('401') ||
      has('403') ||
      has('unauthor') ||
      has('forbidden') ||
      has('credential')) {
    return 'Access was refused. Check your GitHub token in Settings.';
  }
  if (has('429') || has('rate limit')) {
    return 'Rate limit reached. Add a GitHub token in Settings or try again later.';
  }
  if (has('404') || has('not found')) {
    return "The data source couldn't be found. Check the sensor configuration.";
  }
  if (has('500') || has('502') || has('503') || has('server error')) {
    return 'The server had a problem. Please try again shortly.';
  }
  if (has('format') || has('parse') || has('unexpected') || has('invalid')) {
    return "The reading couldn't be read — the sensor may be reporting an unexpected format.";
  }
  return 'Something went wrong. Please try again.';
}
