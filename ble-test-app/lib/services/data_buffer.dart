import 'dart:async';
import 'dart:typed_data';

/// Reassembles incoming BLE byte chunks until the target crash telemetry size
/// (8.4 KB = 8,400 bytes) is achieved.
class CrashDataBuffer {
  /// Default target size for crash event telemetry (8.4 KB = 8,400 bytes)
  static const int defaultTargetSizeBytes = 8400;

  final int targetSizeBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  int _chunkCount = 0;
  DateTime? _firstChunkTimestamp;
  DateTime? _lastChunkTimestamp;

  final StreamController<double> _progressController =
      StreamController<double>.broadcast(sync: true);
  final StreamController<Uint8List> _crashEventController =
      StreamController<Uint8List>.broadcast(sync: true);

  CrashDataBuffer({this.targetSizeBytes = defaultTargetSizeBytes});

  /// Stream of completion progress from 0.0 to 1.0 (0% to 100%)
  Stream<double> get progressStream => _progressController.stream;

  /// Stream emitting completed crash telemetry byte arrays (8.4 KB)
  Stream<Uint8List> get crashEventStream => _crashEventController.stream;

  /// Number of bytes currently collected in the buffer
  int get currentBytes => _builder.length;

  /// Total number of chunks received for current buffer
  int get chunkCount => _chunkCount;

  /// Progress fraction (0.0 to 1.0)
  double get progressFraction {
    if (targetSizeBytes <= 0) return 1.0;
    final frac = _builder.length / targetSizeBytes;
    return frac > 1.0 ? 1.0 : frac;
  }

  /// Progress percentage (0 to 100)
  double get progressPercentage => progressFraction * 100.0;

  /// Calculates the transfer throughput in KB/s
  double get throughputKbps {
    if (_firstChunkTimestamp == null || _lastChunkTimestamp == null) return 0.0;
    final elapsedMs =
        _lastChunkTimestamp!.difference(_firstChunkTimestamp!).inMilliseconds;
    if (elapsedMs <= 0) return 0.0;
    return (_builder.length / 1024.0) / (elapsedMs / 1000.0);
  }

  /// Appends an incoming chunk of bytes to the internal buffer.
  /// When accumulated bytes reach or exceed [targetSizeBytes],
  /// a completed Uint8List is extracted and emitted via [crashEventStream].
  void appendChunk(List<int> chunk) {
    if (chunk.isEmpty) return;

    final now = DateTime.now();
    _firstChunkTimestamp ??= now;
    _lastChunkTimestamp = now;
    _chunkCount++;

    _builder.add(chunk);

    final currentLen = _builder.length;
    _progressController.add(progressFraction);

    if (currentLen >= targetSizeBytes) {
      final allBytes = _builder.takeBytes();

      // Extract exactly targetSizeBytes for the current crash event
      final completedEventData = Uint8List.fromList(
        allBytes.sublist(0, targetSizeBytes),
      );

      // Retain any excess overflow bytes for next event cycle
      if (allBytes.length > targetSizeBytes) {
        final overflowBytes = allBytes.sublist(targetSizeBytes);
        _builder.add(overflowBytes);
        _chunkCount = 1;
        _firstChunkTimestamp = DateTime.now();
      } else {
        _chunkCount = 0;
        _firstChunkTimestamp = null;
      }

      _progressController.add(progressFraction);
      _crashEventController.add(completedEventData);
    }
  }

  /// Resets the buffer and metrics
  void reset() {
    _builder.clear();
    _chunkCount = 0;
    _firstChunkTimestamp = null;
    _lastChunkTimestamp = null;
    _progressController.add(0.0);
  }

  /// Disposes internal stream controllers
  void dispose() {
    _progressController.close();
    _crashEventController.close();
  }
}
