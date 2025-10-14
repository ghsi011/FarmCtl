import 'dart:io';

import 'package:dio/dio.dart';

class GithubTokenTester {
  Future<String> test({String? token}) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        headers: {
          HttpHeaders.userAgentHeader: 'farmctl/0.1',
          HttpHeaders.acceptHeader: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          if (token != null && token.isNotEmpty)
            HttpHeaders.authorizationHeader: 'token $token',
        },
      ),
    );
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.github.com/rate_limit',
      );
      final status = response.statusCode ?? 0;
      if (status == 200) {
        final data = response.data ?? const {};
        final resources = data['resources'] as Map<String, dynamic>?;
        final core = resources != null
            ? resources['core'] as Map<String, dynamic>?
            : null;
        final remaining = core != null ? core['remaining'] as int? : null;
        final limit = core != null ? core['limit'] as int? : null;
        return 'GitHub auth OK: remaining ${remaining ?? '?'} / ${limit ?? '?'}';
      }
      return 'GitHub auth failed: HTTP $status';
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final msg = e.response?.data is Map<String, dynamic>
          ? (e.response?.data as Map<String, dynamic>)['message']
          : e.message;
      return 'GitHub auth error${status != null ? ' ($status)' : ''}: ${msg ?? 'Unknown error'}';
    } catch (e) {
      return 'GitHub auth error: $e';
    }
  }
}
