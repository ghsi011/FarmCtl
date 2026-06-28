/// Rewrites compact on-screen strings into something a screen reader speaks
/// correctly — e.g. `21.5°C` becomes "21.5 degrees Celsius" and the `•`
/// separator becomes a sentence break rather than "bullet".
String spokenText(String input) {
  return input
      .replaceAll('°C', ' degrees Celsius')
      .replaceAll('°', ' degrees')
      .replaceAll('•', '.')
      .replaceAll('–', 'to')
      .replaceAll('  ', ' ')
      .trim();
}
