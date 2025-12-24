import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _statusChannel = 'status';
const String _payloadChannel = 'last_payload';
const String _offlineQueueKey = 'offline_location_queue';
const String _connectivityHost = 'google.com';

Future<bool> _hasInternetConnection() async {
  try {
    final result = await InternetAddress.lookup(_connectivityHost)
        .timeout(const Duration(seconds: 3));
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<List<Map<String, dynamic>>> _loadOfflineQueue() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getStringList(_offlineQueueKey);
  if (stored == null) {
    return <Map<String, dynamic>>[];
  }
  final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
  for (final item in stored) {
    try {
      final decoded = jsonDecode(item);
      if (decoded is Map<String, dynamic>) {
        result.add(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Abaikan item yang tidak bisa didecode.
    }
  }
  return result;
}

Future<void> _saveOfflineQueue(List<Map<String, dynamic>> queue) async {
  final prefs = await SharedPreferences.getInstance();
  final encoded = queue.map((e) => jsonEncode(e)).toList(growable: false);
  await prefs.setStringList(_offlineQueueKey, encoded);
}

Future<int> _enqueueOfflinePayload(Map<String, dynamic> payload) async {
  final queue = await _loadOfflineQueue();
  queue.add(payload);
  const maxQueueLength = 500;
  if (queue.length > maxQueueLength) {
    queue.removeRange(0, queue.length - maxQueueLength);
  }
  await _saveOfflineQueue(queue);
  return queue.length;
}

Future<int> _flushOfflineQueue({
  required ServiceInstance service,
  required MqttServerClient client,
  required TrackerConfig config,
}) async {
  final queue = await _loadOfflineQueue();
  if (queue.isEmpty) {
    return 0;
  }
  final remaining = <Map<String, dynamic>>[];
  for (var i = 0; i < queue.length; i++) {
    final original = queue[i];
    try {
      final sendTime = DateTime.now().toIso8601String();
      final payload = Map<String, dynamic>.from(original)
        ..['sent_at'] = sendTime;
      final builder = MqttClientPayloadBuilder()
        ..addUTF8String(jsonEncode(payload));
      client.publishMessage(
        config.topic,
        MqttQos.exactlyOnce,
        builder.payload!,
      );
      service.invoke(_payloadChannel, payload);
    } catch (_) {
      remaining.addAll(queue.sublist(i));
      break;
    }
  }
  await _saveOfflineQueue(remaining);
  final pending = remaining.length;
  service.invoke(_statusChannel, {
    'status': pending == 0 ? 'Offline queue flushed' : 'Offline queue pending',
    'topic': config.topic,
    'pending': pending,
  });
  return pending;
}

Future<void> initializeBackgroundService() async {
  if (kIsWeb) {
    return;
  }
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      initialNotificationTitle: 'Mobile Tracker',
      initialNotificationContent: 'App is running',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [
        AndroidForegroundType.location,
        AndroidForegroundType.dataSync,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final battery = Battery();
  TrackerConfig? config;
  MqttServerClient? client;
  Timer? ticker;
  var allowReconnect = false;
  var connecting = false;
  var configVersion = 0;

  Future<void> ensureConnected() async {
    if (!allowReconnect || config == null || connecting) {
      return;
    }
    connecting = true;
    try {
      final runVersion = configVersion;
      final newClient = await _connectClient(
        config!,
        service,
        onDisconnected: () {
          client = null;
          if (!allowReconnect) return;
          unawaited(ensureConnected());
        },
      );
      if (!allowReconnect || runVersion != configVersion) {
        newClient?.disconnect();
        return;
      }
      client = newClient;
      if (client != null) {
        try {
          await _flushOfflineQueue(
            service: service,
            client: client!,
            config: config!,
          );
        } catch (_) {
          // Jika flush gagal, biarkan antrean tetap tersimpan untuk dicoba lagi.
        }
      }
    } finally {
      connecting = false;
    }
  }

  Future<void> stopTracking() async {
    allowReconnect = false;
    connecting = false;
    ticker?.cancel();
    ticker = null;
    client?.disconnect();
    client = null;
    config = null;
    configVersion++;
    service.invoke(_statusChannel, {'status': 'Stopped'});
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: 'Mobile Tracker',
        content: 'Tracking berhenti',
      );
    }
  }

  service.on('config').listen((event) async {
    if (event == null) return;
    await stopTracking();
    config = TrackerConfig.fromMap(Map<String, dynamic>.from(event));
    allowReconnect = true;
    if (service is AndroidServiceInstance) {
      await service.setAsForegroundService();
    }

    Future<void> tick() async {
      if (!allowReconnect) return;
      final currentConfig = config;
      if (currentConfig == null) return;
      if (kDebugMode) {
        debugPrint(
          '[BG] tick at ${DateTime.now().toIso8601String()} '
          'allowReconnect=$allowReconnect',
        );
      }
      final needsReconnect = client == null ||
          client!.connectionStatus?.state != MqttConnectionState.connected;
      if (needsReconnect) {
        await ensureConnected();
      }
      await _sendLocationUpdate(
        service: service,
        client: client,
        config: currentConfig,
        battery: battery,
      );
    }

    await tick();
    ticker = Timer.periodic(
      Duration(seconds: config!.intervalSeconds),
      (_) => tick(),
    );
  });

  service.on('stopService').listen((event) async {
    await stopTracking();
    await service.stopSelf();
  });
}

Future<MqttServerClient?> _connectClient(
  TrackerConfig config,
  ServiceInstance service,
    {VoidCallback? onDisconnected}) async {
  final client = MqttServerClient(config.broker, config.clientId)
    ..port = config.port
    ..keepAlivePeriod = 30
    ..logging(on: false);

  client.connectionMessage = MqttConnectMessage()
      .withClientIdentifier(config.clientId)
      .startClean()
      .withWillQos(MqttQos.exactlyOnce);

  client.onDisconnected = () {
    service.invoke(_statusChannel, {'status': 'MQTT disconnected'});
    onDisconnected?.call();
  };

  try {
    await client.connect(
      config.username.isEmpty ? null : config.username,
      config.password.isEmpty ? null : config.password,
    );
    service.invoke(_statusChannel, {
      'status': 'Streaming location...',
      'topic': config.topic,
    });
    return client;
  } catch (error) {
    client.disconnect();
    service.invoke(_statusChannel, {
      'status': 'MQTT connection failed',
      'error': error.toString(),
    });
    return null;
  }
}

Future<void> _sendLocationUpdate({
  required ServiceInstance service,
  required MqttServerClient? client,
  required TrackerConfig config,
  required Battery battery,
}) async {
  final enabled = await Geolocator.isLocationServiceEnabled();
  if (!enabled) {
    service.invoke(_statusChannel, {
      'status': 'GPS disabled',
      'error': 'Aktifkan layanan lokasi pada perangkat.',
    });
    return;
  }

  try {
    if (kDebugMode) {
      debugPrint(
        '[BG] _sendLocationUpdate start at ${DateTime.now().toIso8601String()}',
      );
    }
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.best,
    );
    final batteryLevel = await battery.batteryLevel;
    final now = DateTime.now();
    if (kDebugMode) {
      debugPrint(
        '[BG] _sendLocationUpdate payload at ${now.toIso8601String()}',
      );
    }
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final payload = {
      'device_id': config.deviceId,
      'user': config.user,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'bearing': position.heading,
      'battery': batteryLevel,
      'timestamp': timestamp,
      'date': now.toIso8601String(),
      'topic': config.topic,
    };

    final isConnected = client != null &&
        client.connectionStatus?.state == MqttConnectionState.connected;

    // Selalu anggap payload pending terlebih dahulu.
    final uiPayload = Map<String, dynamic>.from(payload)
      ..['sent_at'] = null;
    service.invoke(_payloadChannel, uiPayload);
    final pendingAfterEnqueue = await _enqueueOfflinePayload(payload);

    final hasInternet = await _hasInternetConnection();
    if (!isConnected || !hasInternet) {
      service.invoke(_statusChannel, {
        'status': 'MQTT offline, buffering',
        'topic': config.topic,
        'pending': pendingAfterEnqueue,
      });
      return;
    }

    final pendingAfterFlush = await _flushOfflineQueue(
      service: service,
      client: client,
      config: config,
    );

    service.invoke(_statusChannel, {
      'status': 'Streaming location...',
      'topic': config.topic,
      'pending': pendingAfterFlush,
    });

    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: 'Mobile Tracker',
        content: 'App is running',
      );
    }
  } catch (error) {
    service.invoke(_statusChannel, {
      'status': 'Location error',
      'error': error.toString(),
    });
  }
}

class TrackerConfig {
  TrackerConfig({
    required this.deviceId,
    required this.user,
    required this.broker,
    required this.port,
    required this.topic,
    required this.clientId,
    required this.username,
    required this.password,
    required this.intervalSeconds,
  });

  factory TrackerConfig.fromMap(Map<String, dynamic> map) {
    return TrackerConfig(
      deviceId: map['device_id']?.toString() ?? '',
      user: map['user']?.toString() ?? '',
      broker: map['broker']?.toString() ?? '',
      port: (map['port'] as num?)?.toInt() ?? 1883,
      topic: map['topic']?.toString() ?? '',
      clientId: map['client_id']?.toString() ??
          'mobile-tracker-${DateTime.now().millisecondsSinceEpoch}',
      username: map['username']?.toString() ?? '',
      password: map['password']?.toString() ?? '',
      intervalSeconds: (map['interval_seconds'] as num?)?.toInt() ?? 10,
    );
  }

  final String deviceId;
  final String user;
  final String broker;
  final int port;
  final String topic;
  final String clientId;
  final String username;
  final String password;
  final int intervalSeconds;
}
