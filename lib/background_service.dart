import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const String _statusChannel = 'status';
const String _payloadChannel = 'last_payload';

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
      initialNotificationContent: 'Menyiapkan GPS tracker...',
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

  Future<void> stopTracking() async {
    ticker?.cancel();
    ticker = null;
    client?.disconnect();
    client = null;
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
    if (service is AndroidServiceInstance) {
      await service.setAsForegroundService();
    }
    client = await _connectClient(config!, service);
    if (client == null) {
      return;
    }

    Future<void> tick() async {
      await _sendLocationUpdate(
        service: service,
        client: client!,
        config: config!,
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
) async {
  final client = MqttServerClient(config.broker, config.clientId)
    ..port = config.port
    ..keepAlivePeriod = 30
    ..logging(on: false);

  client.connectionMessage = MqttConnectMessage()
      .withClientIdentifier(config.clientId)
      .startClean()
      .withWillQos(MqttQos.atLeastOnce);

  client.onDisconnected = () {
    service.invoke(_statusChannel, {'status': 'MQTT disconnected'});
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
  required MqttServerClient client,
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

  if (client.connectionStatus?.state != MqttConnectionState.connected) {
    service.invoke(_statusChannel, {
      'status': 'MQTT disconnected',
      'error': 'Percobaan mengirim dibatalkan.',
    });
    return;
  }

  try {
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.best,
    );
    final batteryLevel = await battery.batteryLevel;
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
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
      'topic': config.topic,
    };

    final builder = MqttClientPayloadBuilder()
      ..addUTF8String(jsonEncode(payload));
    client.publishMessage(config.topic, MqttQos.atLeastOnce, builder.payload!);

    service.invoke(_payloadChannel, payload);
    service.invoke(_statusChannel, {
      'status': 'Streaming location...',
      'topic': config.topic,
    });

    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: 'Mobile Tracker',
        content:
            'Lat:${position.latitude.toStringAsFixed(5)} Lng:${position.longitude.toStringAsFixed(5)}',
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
      intervalSeconds: (map['interval_seconds'] as num?)?.toInt() ?? 15,
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
