import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/crash_event.dart';
import 'services/ble_manager.dart';
import 'services/data_buffer.dart';
import 'services/gateway_client.dart';
import 'services/location_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BleGatewayApp());
}

class BleGatewayApp extends StatelessWidget {
  const BleGatewayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IoT Edge Gateway',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D47A1),
          brightness: Brightness.light,
        ),
        cardTheme: const CardThemeData(
          elevation: 2,
          margin: EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
        cardTheme: const CardThemeData(
          elevation: 2,
          margin: EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      themeMode: ThemeMode.system,
      home: const GatewayDashboardScreen(),
    );
  }
}

class GatewayDashboardScreen extends StatefulWidget {
  const GatewayDashboardScreen({super.key});

  @override
  State<GatewayDashboardScreen> createState() => _GatewayDashboardScreenState();
}

class _GatewayDashboardScreenState extends State<GatewayDashboardScreen> {
  // Services
  late final CrashDataBuffer _dataBuffer;
  late final BleConnectionManager _bleManager;
  late final GatewayClient _gatewayClient;

  // Stream Subscriptions
  StreamSubscription<BleGatewayState>? _bleStateSub;
  StreamSubscription<String>? _bleStatusSub;
  StreamSubscription<double>? _bufferProgressSub;
  StreamSubscription<Uint8List>? _crashEventSub;

  // UI State
  BleGatewayState _bleState = BleGatewayState.idle;
  String _bleStatusMessage = 'Ready to scan for ESP32';
  double _bufferProgress = 0.0;
  int _currentBufferedBytes = 0;
  int _chunkCount = 0;

  // Last Crash Event & Dispatch State
  bool _isProcessingCrash = false;
  CrashEvent? _lastCrashEvent;
  GatewayResponse? _lastDispatchResponse;
  Map<String, dynamic>? _lastLocationData;
  final List<String> _activityLogs = [];

  // Configurable Mock Backend URL
  final TextEditingController _backendUrlController =
      TextEditingController(text: GatewayClient.defaultBackendUrl);

  // Simulation state
  bool _isSimulating = false;
  Timer? _autoScanTimer;

  @override
  void initState() {
    super.initState();
    _initServices();
    _autoStartScan();
  }

  void _initServices() {
    _dataBuffer = CrashDataBuffer(
      targetSizeBytes: CrashDataBuffer.defaultTargetSizeBytes, // 8.4 KB = 8400 bytes
    );

    _bleManager = BleConnectionManager(
      dataBuffer: _dataBuffer,
    );

    _gatewayClient = GatewayClient();

    // Listen to BLE State
    _bleStateSub = _bleManager.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _bleState = state;
        });
        _addLog('[BLE] State: ${state.name}');
      }
    });

    // Listen to BLE Status messages
    _bleStatusSub = _bleManager.statusStream.listen((message) {
      if (mounted) {
        setState(() {
          _bleStatusMessage = message;
        });
        _addLog('[BLE] $message');
      }
    });

    // Listen to Data Buffer Progress (0.0 to 1.0)
    _bufferProgressSub = _dataBuffer.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _bufferProgress = progress;
          _currentBufferedBytes = _dataBuffer.currentBytes;
          _chunkCount = _dataBuffer.chunkCount;
        });
      }
    });

    // Listen to Crash Event Trigger (when buffer reaches 8.4 KB)
    _crashEventSub = _dataBuffer.crashEventStream.listen((completeCrashBytes) {
      _handleCrashEventTriggered(completeCrashBytes);
    });
  }

  void _autoStartScan() {
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        _bleManager.startScan();
      }
    });
  }

  void _addLog(String log) {
    final timeStr = DateTime.now().toLocal().toString().split('.').first;
    setState(() {
      _activityLogs.insert(0, '[$timeStr] $log');
      if (_activityLogs.length > 50) {
        _activityLogs.removeLast();
      }
    });
  }

  /// Triggered immediately when the incoming buffer accumulates the full 8.4 KB
  Future<void> _handleCrashEventTriggered(Uint8List crashBytes) async {
    if (_isProcessingCrash) return;

    setState(() {
      _isProcessingCrash = true;
    });

    _addLog('🚨 CRASH DETECTED! Reassembled 8.4 KB (${crashBytes.length} B).');

    // 1. Immediately fetch device GPS coordinates using Geolocator
    _addLog('📍 Fetching GPS coordinates via Geolocator...');
    final locationData = await LocationService.getCurrentCoordinates();

    if (locationData['status'] == 'PERMISSION_DENIED' ||
        locationData['status'] == 'PERMISSION_DENIED_FOREVER') {
      _addLog('⚠️ Location permission denied! Proceeding without GPS.');
      if (mounted) {
        _showPermissionDeniedSnackBar(locationData['status'] as String);
      }
    } else if (locationData['status'] == 'ACQUIRED' ||
        locationData['status'] == 'LAST_KNOWN') {
      _addLog(
          '✅ GPS Acquired: Lat ${locationData['latitude']}, Lng ${locationData['longitude']} (±${locationData['accuracy']}m)');
    } else {
      _addLog('⚠️ Location status: ${locationData['status']} (${locationData['error']})');
    }

    // 2. Package into CrashEvent (Base64 encoded bytes + GPS coordinates)
    final device = _bleManager.connectedDevice;
    final event = CrashEvent(
      timestamp: DateTime.now(),
      deviceName: device?.platformName.isNotEmpty == true
          ? device!.platformName
          : 'ESP32_ALERT_DEVICE',
      deviceId: device?.remoteId.str ?? 'ESP32-GATEWAY-ID',
      rawBytes: crashBytes,
      location: locationData,
    );

    if (mounted) {
      setState(() {
        _lastCrashEvent = event;
        _lastLocationData = locationData;
      });
    }

    // 3. Execute HTTP POST request to mock backend URL
    final targetBackendUrl = _backendUrlController.text.trim().isNotEmpty
        ? _backendUrlController.text.trim()
        : GatewayClient.defaultBackendUrl;

    _addLog('📤 Executing HTTP POST to $targetBackendUrl...');
    final response = await _gatewayClient.postCrashTelemetry(
      event,
      endpointUrl: targetBackendUrl,
    );

    if (mounted) {
      setState(() {
        _lastDispatchResponse = response;
        _isProcessingCrash = false;
      });

      if (response.success) {
        _addLog(
            '🚀 Telemetry successfully posted! HTTP ${response.statusCode} in ${response.latencyMs}ms.');
      } else {
        _addLog(
            '❌ HTTP POST failed: ${response.errorMessage ?? "Status ${response.statusCode}"}');
      }
    }
  }

  void _showPermissionDeniedSnackBar(String status) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          status == 'PERMISSION_DENIED_FOREVER'
              ? 'Location permission permanently denied. Open settings to allow GPS.'
              : 'Location permission was denied. Crash coordinates unavailable.',
        ),
        backgroundColor: Colors.orange.shade800,
        action: SnackBarAction(
          label: 'SETTINGS',
          textColor: Colors.white,
          onPressed: () => LocationService.openSettings(),
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Simulates an incoming stream of byte chunks from the ESP32 (8.4 KB total)
  /// to verify buffer reassembly, GPS acquisition, and HTTP dispatch without hardware.
  Future<void> _simulateCrashStream() async {
    if (_isSimulating || _isProcessingCrash) return;

    setState(() {
      _isSimulating = true;
    });

    _addLog('🧪 Starting 8.4 KB Crash Stream Simulation...');
    _dataBuffer.reset();

    const totalTarget = CrashDataBuffer.defaultTargetSizeBytes; // 8400 bytes
    const chunkSize = 256; // typical BLE notification chunk size
    final random = Random();

    int sent = 0;
    while (sent < totalTarget && _isSimulating) {
      final int currentChunkSize = min(chunkSize, totalTarget - sent);
      // Generate synthetic IMU / blackbox accelerometer crash telemetry bytes
      final chunk = List<int>.generate(
        currentChunkSize,
        (i) => (sent + i) % 256 ^ (random.nextInt(255)),
      );

      _dataBuffer.appendChunk(chunk);
      sent += currentChunkSize;

      await Future.delayed(const Duration(milliseconds: 35));
    }

    if (mounted) {
      setState(() {
        _isSimulating = false;
      });
    }
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    _bleStateSub?.cancel();
    _bleStatusSub?.cancel();
    _bufferProgressSub?.cancel();
    _crashEventSub?.cancel();
    _dataBuffer.dispose();
    _bleManager.dispose();
    _gatewayClient.close();
    _backendUrlController.dispose();
    super.dispose();
  }

  Color _getStateColor() {
    switch (_bleState) {
      case BleGatewayState.streaming:
        return Colors.green;
      case BleGatewayState.connected:
        return Colors.teal;
      case BleGatewayState.connecting:
      case BleGatewayState.discoveringServices:
      case BleGatewayState.scanning:
        return Colors.blue;
      case BleGatewayState.reconnecting:
        return Colors.orange;
      case BleGatewayState.disconnected:
      case BleGatewayState.bluetoothOff:
      case BleGatewayState.permissionsRequired:
      case BleGatewayState.error:
        return Colors.red;
      case BleGatewayState.idle:
      case BleGatewayState.deviceFound:
        return Colors.grey;
    }
  }

  IconData _getStateIcon() {
    switch (_bleState) {
      case BleGatewayState.streaming:
        return Icons.sensors;
      case BleGatewayState.connected:
        return Icons.bluetooth_connected;
      case BleGatewayState.scanning:
        return Icons.bluetooth_searching;
      case BleGatewayState.reconnecting:
        return Icons.autorenew;
      case BleGatewayState.disconnected:
        return Icons.bluetooth_disabled;
      case BleGatewayState.bluetoothOff:
        return Icons.bluetooth_disabled_outlined;
      case BleGatewayState.error:
        return Icons.error_outline;
      default:
        return Icons.bluetooth;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'AgeisLink Edge Gateway',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            tooltip: 'Clear activity logs',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              setState(() {
                _activityLogs.clear();
              });
            },
          ),
          IconButton(
            tooltip: 'Open App Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => LocationService.openSettings(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _bleManager.startScan();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBleStatusCard(),
              _buildBufferProgressCard(),
              _buildLocationStatusCard(),
              _buildDispatchCard(),
              _buildActionControls(),
              _buildActivityLogCard(),
            ],
          ),
        ),
      ),
    );
  }

  // 1. BLE Connection Status Card
  Widget _buildBleStatusCard() {
    final stateColor = _getStateColor();
    final isReconnecting = _bleState == BleGatewayState.reconnecting;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: stateColor.withValues(alpha: 0.15),
                  child: Icon(_getStateIcon(), color: stateColor, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bleState.name.toUpperCase(),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: stateColor,
                          fontSize: 14,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _bleStatusMessage,
                        style: const TextStyle(fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (_bleState == BleGatewayState.scanning || isReconnecting)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
              ],
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('TARGET SERVICE UUID',
                        style: TextStyle(fontSize: 10, color: Colors.grey)),
                    Text(
                      '${BleConnectionManager.defaultServiceUuid.substring(0, 18)}...',
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('CONNECTED DEVICE',
                        style: TextStyle(fontSize: 10, color: Colors.grey)),
                    Text(
                      _bleManager.connectedDevice?.platformName.isNotEmpty ==
                              true
                          ? _bleManager.connectedDevice!.platformName
                          : (_bleManager.connectedDevice?.remoteId.str ??
                              'None'),
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 2. 8.4 KB Telemetry Buffer Card
  Widget _buildBufferProgressCard() {
    final percentage = (_bufferProgress * 100).toStringAsFixed(1);
    final targetKb =
        (CrashDataBuffer.defaultTargetSizeBytes / 1024.0).toStringAsFixed(1);
    final currentKb = (_currentBufferedBytes / 1024.0).toStringAsFixed(2);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.memory, size: 20, color: Colors.indigo),
                    SizedBox(width: 8),
                    Text(
                      '8.4 KB Crash Data Buffer',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ],
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _bufferProgress >= 1.0
                        ? Colors.red.withValues(alpha: 0.15)
                        : Colors.indigo.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _bufferProgress >= 1.0
                        ? 'CRASH ARMED'
                        : '$percentage%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _bufferProgress >= 1.0
                          ? Colors.red
                          : Colors.indigo,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _bufferProgress,
                minHeight: 12,
                backgroundColor: Colors.grey.shade300,
                color: _bufferProgress >= 1.0 ? Colors.red : Colors.indigo,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Reassembled: $_currentBufferedBytes / ${CrashDataBuffer.defaultTargetSizeBytes} B ($currentKb / $targetKb KB)',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  'Chunks: $_chunkCount',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 3. Location Status Card
  Widget _buildLocationStatusCard() {
    final location = _lastLocationData;
    final status = location?['status'] ?? 'NOT_FETCHED';
    final isAcquired = status == 'ACQUIRED' || status == 'LAST_KNOWN';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.location_on, size: 20, color: Colors.teal),
                    SizedBox(width: 8),
                    Text(
                      'GPS Position Acquisition',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ],
                ),
                Chip(
                  label: Text(status, style: const TextStyle(fontSize: 10)),
                  backgroundColor: isAcquired
                      ? Colors.teal.shade50
                      : Colors.orange.shade50,
                  side: BorderSide(
                    color: isAcquired ? Colors.teal : Colors.orange,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (isAcquired && location != null) ...[
              Text(
                'Latitude: ${location['latitude']} | Longitude: ${location['longitude']}',
                style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Accuracy: ±${location['accuracy']}m | Altitude: ${location['altitude']}m',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              if (location['maps_url'] != null) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final uri = Uri.parse(location['maps_url']);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri);
                    }
                  },
                  child: Text(
                    '📍 Open Coordinates in Maps',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ] else ...[
              Text(
                location?['error'] ??
                    'GPS coordinates will be captured immediately upon 8.4 KB buffer completion.',
                style: TextStyle(
                  fontSize: 12,
                  color: location?['error'] != null
                      ? Colors.red.shade700
                      : Colors.grey.shade600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 4. HTTP Backend Dispatch Card
  Widget _buildDispatchCard() {
    final response = _lastDispatchResponse;
    final event = _lastCrashEvent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cloud_upload, size: 20, color: Colors.purple),
                SizedBox(width: 8),
                Text(
                  'Mock Backend Dispatch (HTTP POST)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _backendUrlController,
              decoration: const InputDecoration(
                labelText: 'Backend URL Endpoint',
                hintText: 'https://httpbin.org/post',
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link, size: 18),
              ),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            if (_isProcessingCrash) ...[
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Packaging Base64 and dispatching to backend...',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ] else if (response != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: response.success
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: response.success
                        ? Colors.green.shade300
                        : Colors.red.shade300,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          response.success
                              ? 'HTTP ${response.statusCode} OK'
                              : 'FAILED (${response.statusCode ?? "Error"})',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: response.success
                                ? Colors.green.shade900
                                : Colors.red.shade900,
                          ),
                        ),
                        Text(
                          '${response.latencyMs} ms',
                          style: TextStyle(
                            fontSize: 11,
                            color: response.success
                                ? Colors.green.shade800
                                : Colors.red.shade800,
                          ),
                        ),
                      ],
                    ),
                    if (response.errorMessage != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        response.errorMessage!,
                        style: TextStyle(
                            fontSize: 12, color: Colors.red.shade900),
                      ),
                    ],
                  ],
                ),
              ),
            ] else ...[
              Text(
                'No payload dispatched yet.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
            if (event != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.code, size: 16),
                label: const Text('View Dispatched JSON Payload',
                    style: TextStyle(fontSize: 12)),
                onPressed: () => _showPayloadDialog(event),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPayloadDialog(CrashEvent event) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dispatched JSON Payload',
            style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              event.toPrettyJson(),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // 5. Action Controls
  Widget _buildActionControls() {
    final isConnected = _bleState == BleGatewayState.connected ||
        _bleState == BleGatewayState.streaming;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isConnected ? Colors.grey.shade700 : const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: Icon(
                      isConnected ? Icons.bluetooth_disabled : Icons.search),
                  label: Text(isConnected ? 'Disconnect' : 'Scan & Connect'),
                  onPressed: () {
                    if (isConnected) {
                      _bleManager.disconnect();
                    } else {
                      _bleManager.startScan();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: _isSimulating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.flash_on),
                  label: Text(_isSimulating
                      ? 'Simulating...'
                      : 'Simulate 8.4 KB Crash'),
                  onPressed:
                      _isSimulating ? null : () => _simulateCrashStream(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 6. Activity Logs
  Widget _buildActivityLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.terminal, size: 18, color: Colors.blueGrey),
                    SizedBox(width: 8),
                    Text(
                      'Gateway Activity Log',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ],
                ),
                Text(
                  '${_activityLogs.length} events',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 160,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _activityLogs.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs yet. Activity will appear here.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _activityLogs.length,
                      itemBuilder: (context, index) {
                        final log = _activityLogs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            log,
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}