import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/crash_event.dart';

/// Result summary of an HTTP dispatch attempt
class GatewayResponse {
  final bool success;
  final int? statusCode;
  final String? responseBody;
  final String? errorMessage;
  final int latencyMs;
  final DateTime timestamp;

  GatewayResponse({
    required this.success,
    this.statusCode,
    this.responseBody,
    this.errorMessage,
    required this.latencyMs,
    required this.timestamp,
  });
}

/// Dispatches telemetry payloads to the backend API via HTTP POST.
class GatewayClient {
  /// Default mock backend endpoint (mirrors sent payload and headers)
  static const String defaultBackendUrl = 'https://httpbin.org/post';

  final http.Client _client;

  GatewayClient({http.Client? client}) : _client = client ?? http.Client();

  /// Posts a [CrashEvent] to [endpointUrl].
  Future<GatewayResponse> postCrashTelemetry(
    CrashEvent event, {
    String endpointUrl = defaultBackendUrl,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final startTime = DateTime.now();
    final uri = Uri.parse(endpointUrl);
    final jsonPayload = jsonEncode(event.toJson());

    debugPrint(
        '[GatewayClient] Posting crash telemetry (${event.byteCount} B) to $endpointUrl...');

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'X-Gateway-Device': event.deviceName,
              'X-Gateway-Event': event.eventType,
            },
            body: jsonPayload,
          )
          .timeout(timeout);

      final latency =
          DateTime.now().difference(startTime).inMilliseconds;

      final isSuccess =
          response.statusCode >= 200 && response.statusCode < 300;

      debugPrint(
          '[GatewayClient] Backend response ${response.statusCode} in ${latency}ms.');

      return GatewayResponse(
        success: isSuccess,
        statusCode: response.statusCode,
        responseBody: response.body,
        latencyMs: latency,
        timestamp: DateTime.now(),
      );
    } on SocketException catch (e) {
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('[GatewayClient] Socket exception: $e');
      return GatewayResponse(
        success: false,
        errorMessage: 'Network error (offline or unreachable): ${e.message}',
        latencyMs: latency,
        timestamp: DateTime.now(),
      );
    } on TimeoutException {
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('[GatewayClient] Request timed out after $timeout');
      return GatewayResponse(
        success: false,
        errorMessage: 'Request timed out after ${timeout.inSeconds} seconds',
        latencyMs: latency,
        timestamp: DateTime.now(),
      );
    } on http.ClientException catch (e) {
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('[GatewayClient] HTTP client exception: $e');
      return GatewayResponse(
        success: false,
        errorMessage: 'HTTP client error: ${e.message}',
        latencyMs: latency,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('[GatewayClient] Unexpected dispatch error: $e');
      return GatewayResponse(
        success: false,
        errorMessage: 'Unexpected error: $e',
        latencyMs: latency,
        timestamp: DateTime.now(),
      );
    }
  }

  void close() {
    _client.close();
  }
}
