import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/format/error_messages.dart';
import 'package:farmctl/core/format/relative_time.dart';
import 'package:farmctl/core/format/semantics_text.dart';

void main() {
  group('humanizeError', () {
    test('maps connectivity failures to a friendly message', () {
      expect(
        humanizeError(Exception('SocketException: Failed host lookup')),
        contains("Couldn't reach the server"),
      );
      expect(
        humanizeError('Connection closed'),
        contains("Couldn't reach the server"),
      );
    });

    test('maps timeouts, auth, rate-limit and server errors', () {
      expect(humanizeError('Request timed out'), contains('timed out'));
      expect(humanizeError('HTTP 401 Unauthorized'), contains('GitHub token'));
      expect(humanizeError('429 rate limit'), contains('Rate limit'));
      expect(
        humanizeError('500 server error'),
        contains('server had a problem'),
      );
    });

    test('maps parse problems and falls back generically', () {
      expect(
        humanizeError('FormatException: unexpected token'),
        contains("couldn't be read"),
      );
      expect(humanizeError(null), contains('Something went wrong'));
      expect(humanizeError('totally opaque'), contains('Something went wrong'));
    });
  });

  group('formatRelativeDuration', () {
    test('describes recent and older spans', () {
      expect(formatRelativeDuration(const Duration(seconds: 30)), 'just now');
      expect(formatRelativeDuration(const Duration(minutes: 1)), '1 min ago');
      expect(formatRelativeDuration(const Duration(minutes: 5)), '5 mins ago');
      expect(formatRelativeDuration(const Duration(hours: 1)), '1 hour ago');
      expect(formatRelativeDuration(const Duration(hours: 3)), '3 hours ago');
      expect(formatRelativeDuration(const Duration(days: 2)), '2 days ago');
    });
  });

  group('formatElapsed', () {
    test('describes an out-of-range span without an "ago" suffix', () {
      expect(formatElapsed(const Duration(seconds: 30)), 'less than a minute');
      expect(formatElapsed(const Duration(minutes: 1)), '1 minute');
      expect(formatElapsed(const Duration(minutes: 45)), '45 minutes');
      expect(
        formatElapsed(const Duration(hours: 2, minutes: 14)),
        '2 hours 14 min',
      );
      expect(formatElapsed(const Duration(hours: 3)), '3 hours');
      expect(formatElapsed(const Duration(days: 1, hours: 2)), '1 day 2 h');
      expect(formatElapsed(const Duration(days: 2)), '2 days');
    });
  });

  group('spokenText', () {
    test('expands units and separators for screen readers', () {
      expect(spokenText('21.5°C'), '21.5 degrees Celsius');
      expect(
        spokenText('Out of range • 25°C'),
        'Out of range . 25 degrees Celsius',
      );
      expect(spokenText('10 – 20'), '10 to 20');
    });
  });
}
