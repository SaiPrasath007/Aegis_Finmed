import 'dart:convert';
import 'dart:typed_data';

/// Represents a crash telemetry event captured by the IoT Edge Gateway.
class CrashEvent {
  final DateTime timestamp;
  final String deviceName;
  final String deviceId;
  final Uint8List rawBytes;
  final Map<String, dynamic> location;
  final String eventType;

  CrashEvent({
    required this.timestamp,
    required this.deviceName,
    required this.deviceId,
    required this.rawBytes,
    required this.location,
    this.eventType = 'CRASH_EVENT',
  });

  /// Base64 encoded representation of the raw byte array
  String get base64Data => base64Encode(rawBytes);

  /// Total size of the reassembled payload in bytes
  int get byteCount => rawBytes.length;

  /// Serializes into JSON payload required by the mock backend
  Map<String, dynamic> toJson() {
    return {
      'event': eventType,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'device': {
        'name': deviceName,
        'id': deviceId,
      },
      'payload': {
        'size_bytes': byteCount,
        'size_kb': (byteCount / 1024).toStringAsFixed(2),
        'telemetry_base64': base64Data,
      },
      'location': location,
      'gateway_metadata': {
        'agent': 'AgeisLink IoT Edge Gateway',
        'version': '1.0.0',
      }
    };
  }

  /// Formatted JSON string for display and logging
  String toPrettyJson() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toJson());
  }
}
