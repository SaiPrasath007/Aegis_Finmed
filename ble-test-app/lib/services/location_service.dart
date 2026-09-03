import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Service responsible for acquiring GPS coordinates and gracefully handling
/// permission denials and service disablement.
class LocationService {
  /// Fetches current GPS coordinates with robust error handling for permissions.
  /// Always returns a structured Map, ensuring the crash telemetry payload
  /// is never blocked even when GPS is denied or unavailable.
  static Future<Map<String, dynamic>> getCurrentCoordinates() async {
    try {
      // 1. Check if location services are enabled
      final isServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isServiceEnabled) {
        debugPrint('[LocationService] Location services are disabled.');
        return {
          'status': 'SERVICE_DISABLED',
          'error': 'Location services are disabled on device.',
        };
      }

      // 2. Check and request permissions
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('[LocationService] Permission denied. Requesting permission...');
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('[LocationService] Permission denied by user.');
          return {
            'status': 'PERMISSION_DENIED',
            'error': 'Location permission was denied by user.',
          };
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('[LocationService] Permission denied forever.');
        return {
          'status': 'PERMISSION_DENIED_FOREVER',
          'error':
              'Location permission permanently denied. Enable in device settings.',
        };
      }

      // 3. Attempt to fetch current high-accuracy GPS fix
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 8),
        );

        return {
          'status': 'ACQUIRED',
          'latitude': position.latitude,
          'longitude': position.longitude,
          'altitude': position.altitude,
          'accuracy': position.accuracy,
          'speed': position.speed,
          'heading': position.heading,
          'timestamp': position.timestamp.toIso8601String(),
          'is_mocked': position.isMocked,
          'maps_url':
              'https://maps.google.com/?q=${position.latitude},${position.longitude}',
        };
      } on TimeoutException {
        debugPrint('[LocationService] Current GPS fix timed out. Falling back to last known position.');
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) {
          return {
            'status': 'LAST_KNOWN',
            'latitude': lastKnown.latitude,
            'longitude': lastKnown.longitude,
            'altitude': lastKnown.altitude,
            'accuracy': lastKnown.accuracy,
            'speed': lastKnown.speed,
            'heading': lastKnown.heading,
            'timestamp': lastKnown.timestamp.toIso8601String(),
            'is_mocked': lastKnown.isMocked,
            'maps_url':
                'https://maps.google.com/?q=${lastKnown.latitude},${lastKnown.longitude}',
            'note': 'Current fix timed out; used last known location cache.',
          };
        }
        return {
          'status': 'TIMEOUT',
          'error': 'GPS acquisition timed out and no cached position is available.',
        };
      }
    } catch (e, stackTrace) {
      debugPrint('[LocationService] Unexpected error acquiring GPS: $e\n$stackTrace');
      return {
        'status': 'ERROR',
        'error': e.toString(),
      };
    }
  }

  /// Opens the device settings screen so user can grant permissions if denied forever.
  static Future<bool> openSettings() async {
    return await Geolocator.openAppSettings();
  }

  /// Opens location service settings screen if GPS is turned off.
  static Future<bool> openLocationSettings() async {
    return await Geolocator.openLocationSettings();
  }
}
