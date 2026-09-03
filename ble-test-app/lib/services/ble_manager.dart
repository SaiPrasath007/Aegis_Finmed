import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'data_buffer.dart';

/// Connection states for the BLE Gateway
enum BleGatewayState {
  idle,
  permissionsRequired,
  bluetoothOff,
  scanning,
  deviceFound,
  connecting,
  discoveringServices,
  connected,
  streaming,
  disconnected,
  reconnecting,
  error,
}

/// BLE Connection Manager responsible for:
/// - Scanning for designated ESP32 service UUID
/// - Connecting and discovering GATT services & characteristics
/// - Subscribing to notifications and piping chunks into [CrashDataBuffer]
/// - Handling abrupt disconnects with automatic backoff reconnection
class BleConnectionManager {
  /// Designated ESP32 Service UUID (Standard 128-bit custom GATT service)
  static const String defaultServiceUuid =
      '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  /// Designated ESP32 Characteristic UUID
  static const String defaultCharUuid =
      'beb5483e-36e1-4688-b7f5-ea07361b26a8';

  final String targetServiceUuid;
  final String targetCharUuid;
  final CrashDataBuffer dataBuffer;

  BleGatewayState _state = BleGatewayState.idle;
  String _statusMessage = 'Ready to scan';
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _notifyCharacteristic;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<int>>? _charDataSub;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 5;
  bool _manualDisconnect = false;

  final StreamController<BleGatewayState> _stateController =
      StreamController<BleGatewayState>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  BleConnectionManager({
    this.targetServiceUuid = defaultServiceUuid,
    this.targetCharUuid = defaultCharUuid,
    required this.dataBuffer,
  }) {
    _initAdapterListener();
  }

  BleGatewayState get state => _state;
  String get statusMessage => _statusMessage;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothCharacteristic? get notifyCharacteristic => _notifyCharacteristic;
  int get reconnectAttempts => _reconnectAttempts;

  Stream<BleGatewayState> get stateStream => _stateController.stream;
  Stream<String> get statusStream => _statusController.stream;

  void _updateState(BleGatewayState newState, String message) {
    _state = newState;
    _statusMessage = message;
    debugPrint('[BLEManager] [${newState.name}] $message');
    _stateController.add(newState);
    _statusController.add(message);
  }

  void _initAdapterListener() {
    try {
      _adapterStateSub = FlutterBluePlus.adapterState.listen(
        (adapterState) {
          if (adapterState != BluetoothAdapterState.on) {
            if (_state != BleGatewayState.bluetoothOff &&
                _state != BleGatewayState.permissionsRequired) {
              _updateState(
                BleGatewayState.bluetoothOff,
                'Bluetooth is turned OFF. Please enable Bluetooth.',
              );
            }
          }
        },
        onError: (err) {
          debugPrint('[BLEManager] Adapter state error: $err');
        },
      );
    } catch (e) {
      debugPrint('[BLEManager] Bluetooth platform interface unavailable: $e');
    }
  }

  /// Request runtime permissions for Android & iOS
  Future<bool> requestPermissions() async {
    try {
      final scanStatus = await Permission.bluetoothScan.request();
      final connectStatus = await Permission.bluetoothConnect.request();
      final locationStatus = await Permission.locationWhenInUse.request();

      final granted = (scanStatus.isGranted || scanStatus.isLimited) &&
          (connectStatus.isGranted || connectStatus.isLimited) &&
          (locationStatus.isGranted || locationStatus.isLimited);

      if (!granted) {
        _updateState(
          BleGatewayState.permissionsRequired,
          'Bluetooth & Location permissions are required to scan.',
        );
      }
      return granted;
    } catch (e) {
      debugPrint('[BLEManager] Error requesting permissions: $e');
      return false;
    }
  }

  /// Starts scanning for devices advertising the designated ESP32 service UUID
  Future<void> startScan({Duration scanTimeout = const Duration(seconds: 15)}) async {
    _manualDisconnect = false;
    _cancelReconnect();

    try {
      // Check adapter state
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _updateState(
          BleGatewayState.bluetoothOff,
          'Bluetooth is OFF. Please enable Bluetooth on this device.',
        );
        return;
      }
    } catch (e) {
      _updateState(
        BleGatewayState.error,
        'Bluetooth interface unavailable: $e',
      );
      return;
    }

    final hasPermissions = await requestPermissions();
    if (!hasPermissions) return;

    _updateState(
      BleGatewayState.scanning,
      'Scanning for ESP32 Service ($targetServiceUuid)...',
    );

    await _scanSub?.cancel();
    _scanSub = null;

    try {
      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: scanTimeout,
        androidUsesFineLocation: true,
      );

      _scanSub = FlutterBluePlus.scanResults.listen(
        (results) async {
          for (final r in results) {
            final serviceUuids = r.advertisementData.serviceUuids
                .map((u) => u.str.toLowerCase())
                .toList();

            final targetUuidClean = targetServiceUuid.toLowerCase().replaceAll('-', '');
            final matchesServiceUuid = serviceUuids.any((u) =>
                u.toLowerCase().replaceAll('-', '') == targetUuidClean);

            // Fallback matching by device name if advertisement data doesn't include service UUID
            final devName = (r.advertisementData.advName.isNotEmpty
                    ? r.advertisementData.advName
                    : r.device.platformName)
                .toUpperCase();
            final matchesName = devName.contains('ESP32') ||
                devName.contains('CRASH') ||
                devName.contains('ALERT');

            if (matchesServiceUuid || matchesName) {
              _updateState(
                BleGatewayState.deviceFound,
                'Found ${r.device.platformName.isEmpty ? "ESP32 Target" : r.device.platformName} (${r.device.remoteId.str})',
              );
              await FlutterBluePlus.stopScan();
              await _scanSub?.cancel();
              _scanSub = null;

              await connectToDevice(r.device);
              return;
            }
          }
        },
        onError: (err) {
          _updateState(
            BleGatewayState.error,
            'Scan error: $err',
          );
        },
      );
    } catch (e) {
      _updateState(
        BleGatewayState.error,
        'Failed to start scan: $e',
      );
    }
  }

  /// Connects to the designated device, sets up disconnect listeners,
  /// requests MTU, and discovers services.
  Future<void> connectToDevice(BluetoothDevice device) async {
    _connectedDevice = device;
    _updateState(
      BleGatewayState.connecting,
      'Connecting to ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}...',
    );

    // Setup connection state listener for disconnect detection & auto-reconnect
    await _connStateSub?.cancel();
    _connStateSub = device.connectionState.listen(
      (connectionState) {
        _handleConnectionStateChange(connectionState);
      },
    );

    try {
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      _reconnectAttempts = 0; // Reset backoff on successful connect

      // Request maximum MTU (up to 512) for high-speed chunk streaming
      try {
        await device.requestMtu(512);
        debugPrint('[BLEManager] MTU negotiation requested (512 bytes).');
      } catch (e) {
        debugPrint('[BLEManager] MTU request ignored or not supported: $e');
      }

      await _discoverServicesAndSubscribe(device);
    } catch (e) {
      _updateState(
        BleGatewayState.error,
        'Connection failed: $e',
      );
      _scheduleAutoReconnect();
    }
  }

  /// Discovers GATT services and subscribes to the designated characteristic
  Future<void> _discoverServicesAndSubscribe(BluetoothDevice device) async {
    _updateState(
      BleGatewayState.discoveringServices,
      'Discovering GATT services...',
    );

    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? targetChar;

      final targetUuidClean = targetServiceUuid.toLowerCase().replaceAll('-', '');
      final targetCharUuidClean =
          targetCharUuid.toLowerCase().replaceAll('-', '');

      // 1. Try to find the exact designated service & characteristic
      for (final s in services) {
        final serviceClean = s.uuid.str.toLowerCase().replaceAll('-', '');
        if (serviceClean == targetUuidClean) {
          for (final c in s.characteristics) {
            final charClean = c.uuid.str.toLowerCase().replaceAll('-', '');
            if (charClean == targetCharUuidClean || c.properties.notify) {
              targetChar = c;
              break;
            }
          }
        }
        if (targetChar != null) break;
      }

      // 2. Fallback: find any characteristic that supports notify
      if (targetChar == null) {
        for (final s in services) {
          for (final c in s.characteristics) {
            if (c.properties.notify) {
              targetChar = c;
              break;
            }
          }
          if (targetChar != null) break;
        }
      }

      if (targetChar == null) {
        _updateState(
          BleGatewayState.error,
          'No notification characteristic found on ${device.platformName}',
        );
        return;
      }

      _notifyCharacteristic = targetChar;
      await _subscribeToCharacteristic(targetChar);
    } catch (e) {
      _updateState(
        BleGatewayState.error,
        'Service discovery failed: $e',
      );
      _scheduleAutoReconnect();
    }
  }

  /// Subscribes to characteristic notifications and passes chunks into dataBuffer
  Future<void> _subscribeToCharacteristic(
      BluetoothCharacteristic characteristic) async {
    try {
      await characteristic.setNotifyValue(true);
      await _charDataSub?.cancel();

      // Listen to incoming chunks
      _charDataSub = characteristic.onValueReceived.listen(
        (chunk) {
          if (chunk.isNotEmpty) {
            dataBuffer.appendChunk(chunk);
          }
        },
        onError: (err) {
          debugPrint('[BLEManager] Error receiving notification: $err');
        },
      );

      _updateState(
        BleGatewayState.streaming,
        'Subscribed to characteristic ${characteristic.uuid.str}. Streaming active.',
      );
    } catch (e) {
      _updateState(
        BleGatewayState.error,
        'Failed to subscribe to characteristic: $e',
      );
    }
  }

  /// Handles connection state changes, detecting disconnects and triggering recovery
  void _handleConnectionStateChange(BluetoothConnectionState connectionState) {
    debugPrint('[BLEManager] ConnectionState: ${connectionState.name}');
    if (connectionState == BluetoothConnectionState.connected) {
      _reconnectAttempts = 0;
    } else if (connectionState == BluetoothConnectionState.disconnected) {
      _tearDownSubscriptions();

      if (!_manualDisconnect) {
        _updateState(
          BleGatewayState.disconnected,
          'Device disconnected unexpectedly.',
        );
        _scheduleAutoReconnect();
      } else {
        _updateState(
          BleGatewayState.disconnected,
          'Device disconnected by user.',
        );
      }
    }
  }

  /// Schedules an auto-reconnect attempt with exponential backoff
  void _scheduleAutoReconnect() {
    if (_manualDisconnect) return;

    if (_reconnectAttempts >= maxReconnectAttempts) {
      _updateState(
        BleGatewayState.error,
        'Max reconnect attempts reached ($maxReconnectAttempts). Please reconnect manually.',
      );
      return;
    }

    _reconnectAttempts++;
    // Exponential backoff: 2s, 4s, 8s, 16s... capped at 15s
    final delaySeconds = min(pow(2, _reconnectAttempts).toInt(), 15);

    _updateState(
      BleGatewayState.reconnecting,
      'Reconnecting in ${delaySeconds}s (Attempt $_reconnectAttempts of $maxReconnectAttempts)...',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_connectedDevice != null) {
        debugPrint('[BLEManager] Attempting reconnect to ${_connectedDevice!.remoteId.str}...');
        connectToDevice(_connectedDevice!);
      } else {
        debugPrint('[BLEManager] Restarting scan for reconnect...');
        startScan();
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
  }

  void _tearDownSubscriptions() {
    _charDataSub?.cancel();
    _charDataSub = null;
    _notifyCharacteristic = null;
  }

  /// Disconnects manually and cleans up resources
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _cancelReconnect();
    _tearDownSubscriptions();

    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (e) {
        debugPrint('[BLEManager] Disconnect error: $e');
      }
      _connectedDevice = null;
    }

    await _connStateSub?.cancel();
    _connStateSub = null;

    _updateState(BleGatewayState.idle, 'Disconnected.');
  }

  void dispose() {
    _manualDisconnect = true;
    _cancelReconnect();
    _tearDownSubscriptions();
    _scanSub?.cancel();
    _connStateSub?.cancel();
    _adapterStateSub?.cancel();
    _stateController.close();
    _statusController.close();
  }
}
