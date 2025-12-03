import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  runApp(const MobileTrackerApp());
}

class MobileTrackerApp extends StatelessWidget {
  const MobileTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobile GPS Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const TrackerHomePage(),
    );
  }
}

class TrackerHomePage extends StatefulWidget {
  const TrackerHomePage({super.key});

  @override
  State<TrackerHomePage> createState() => _TrackerHomePageState();
}

class _TrackerHomePageState extends State<TrackerHomePage> {
  final _formKey = GlobalKey<FormState>();
  final _deviceIdController = TextEditingController(text: 'android-001');
  final _userController = TextEditingController(text: 'driver-1');
  final _brokerController = TextEditingController(text: 'mqtt.burhanfs.my.id');
  final _portController = TextEditingController(text: '1883');
  final _topicController =
      TextEditingController(text: 'tracking/android/android-001/location');
  final _clientIdController = TextEditingController(
    text: 'mobile-tracker-${DateTime.now().millisecondsSinceEpoch}',
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  final Battery _battery = Battery();
  MqttServerClient? _client;
  StreamSubscription<Position>? _positionSub;
  Timer? _batteryTimer;
  bool _isStreaming = false;
  String _status = 'Disconnected';
  String? _errorMessage;
  Position? _lastPosition;
  DateTime? _lastPublish;
  String? _activeTopic;
  String? _activeDeviceId;
  String? _activeUser;
  int? _batteryLevel;

  @override
  void dispose() {
    _positionSub?.cancel();
    _client?.disconnect();
    _batteryTimer?.cancel();
    _deviceIdController.dispose();
    _userController.dispose();
    _brokerController.dispose();
    _portController.dispose();
    _topicController.dispose();
    _clientIdController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _toggleStreaming() async {
    if (_isStreaming) {
      await _stopStreaming();
    } else {
      final isValid = _formKey.currentState?.validate() ?? false;
      if (!isValid) {
        return;
      }
      await _startStreaming();
    }
  }

  Future<void> _startStreaming() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _status = 'Checking GPS permission...';
      _errorMessage = null;
    });

    try {
      await _ensureLocationPermission();
    } catch (error) {
      setState(() {
        _status = 'Permission error';
        _errorMessage = error.toString();
      });
      return;
    }

    final client = await _connectMqtt();
    if (client == null) {
      return;
    }

    final topic = _topicController.text.trim();
    final deviceId = _deviceIdController.text.trim();
    final user = _userController.text.trim();
    final locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5,
    );

    setState(() {
      _client = client;
      _isStreaming = true;
      _status = 'Streaming location...';
      _activeTopic = topic;
      _activeDeviceId = deviceId;
      _activeUser = user;
    });

    await _startBatteryUpdates();

    // Send an initial reading immediately.
    try {
      final currentPosition = await Geolocator.getCurrentPosition();
      _publishPosition(currentPosition);
    } catch (_) {
      // Ignore when immediate fix is unavailable.
    }

    _positionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _publishPosition,
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'Location error: $error';
        });
      },
    );
  }

  Future<void> _stopStreaming() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _client?.disconnect();
    _batteryTimer?.cancel();
    _batteryTimer = null;
    setState(() {
      _client = null;
      _isStreaming = false;
      _status = 'Disconnected';
      _activeTopic = null;
      _activeDeviceId = null;
      _activeUser = null;
    });
  }

  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('GPS pada perangkat belum aktif.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception(
        'Izin lokasi diperlukan untuk mengirim data GPS. '
        'Aktifkan melalui pengaturan perangkat.',
      );
    }
  }

  Future<MqttServerClient?> _connectMqtt() async {
    final broker = _brokerController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 1883;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final clientId = _clientIdText;

    final client = MqttServerClient(broker, clientId)
      ..port = port
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..onDisconnected = _handleDisconnected;

    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();

    setState(() {
      _status = 'Connecting to MQTT...';
    });

    try {
      await client.connect(
        username.isEmpty ? null : username,
        password.isEmpty ? null : password,
      );
      return client;
    } on NoConnectionException catch (error) {
      client.disconnect();
      setState(() {
        _status = 'MQTT connection failed';
        _errorMessage = error.toString();
      });
    } catch (error) {
      client.disconnect();
      setState(() {
        _status = 'MQTT connection failed';
        _errorMessage = error.toString();
      });
    }
    return null;
  }

  Future<void> _startBatteryUpdates() async {
    await _updateBatteryLevel();
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _updateBatteryLevel(),
    );
  }

  Future<void> _updateBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (!mounted) return;
      setState(() {
        _batteryLevel = level;
      });
    } catch (_) {
      // Ignore battery plugin failures.
    }
  }

  void _handleDisconnected() {
    _positionSub?.cancel();
    _positionSub = null;
    _batteryTimer?.cancel();
    _batteryTimer = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _client = null;
      _isStreaming = false;
      _status = 'Disconnected';
      _activeTopic = null;
      _activeDeviceId = null;
      _activeUser = null;
    });
  }

  void _publishPosition(Position position) {
    final client = _client;
    final topic = _activeTopic;
    if (client == null || topic == null) {
      return;
    }

    final deviceId = _activeDeviceId ?? _deviceIdController.text.trim();
    final user = _activeUser ?? _userController.text.trim();
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final payload = jsonEncode({
      'device_id': deviceId,
      'user': user,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'bearing': position.heading,
      'battery': _batteryLevel ?? -1,
      'timestamp': timestamp,
    });

    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);

    if (!mounted) {
      return;
    }
    setState(() {
      _lastPosition = position;
      _lastPublish = DateTime.now();
    });
  }

  String get _clientIdText {
    final value = _clientIdController.text.trim();
    if (value.isNotEmpty) {
      return value;
    }
    return 'mobile-tracker-${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile GPS Tracker'),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTextField(
                  controller: _deviceIdController,
                  label: 'Device ID',
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Device ID wajib diisi';
                    }
                    return null;
                  },
                ),
                _buildTextField(
                  controller: _userController,
                  label: 'User',
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'User wajib diisi';
                    }
                    return null;
                  },
                ),
                _buildTextField(
                  controller: _brokerController,
                  label: 'MQTT Broker',
                  hint: 'contoh: test.mosquitto.org',
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Broker tidak boleh kosong';
                    }
                    return null;
                  },
                ),
                _buildTextField(
                  controller: _portController,
                  label: 'Port',
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    final number = int.tryParse(value ?? '');
                    if (number == null || number <= 0) {
                      return 'Gunakan port yang valid';
                    }
                    return null;
                  },
                ),
                _buildTextField(
                  controller: _topicController,
                  label: 'Topic',
                  hint: 'contoh: devices/mobile_tracker',
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Topic tidak boleh kosong';
                    }
                    return null;
                  },
                ),
                _buildTextField(
                  controller: _clientIdController,
                  label: 'Client ID',
                  hint: 'Opsional, otomatis jika dikosongkan',
                ),
                _buildTextField(
                  controller: _usernameController,
                  label: 'Username (opsional)',
                ),
                _buildTextField(
                  controller: _passwordController,
                  label: 'Password (opsional)',
                  obscureText: true,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _toggleStreaming,
                  icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _isStreaming ? 'Stop Streaming' : 'Start Streaming',
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: Icon(
                      _isStreaming ? Icons.cloud_done : Icons.cloud_off,
                      color: _isStreaming ? Colors.green : Colors.red,
                    ),
                    title: const Text('Status'),
                    subtitle: Text(_status),
                  ),
                ),
                if (_lastPosition != null)
                  Card(
                    child: ListTile(
                      title: const Text('Data GPS terakhir'),
                      subtitle: Text(
                        'Lat: ${_lastPosition!.latitude.toStringAsFixed(6)}\n'
                        'Lng: ${_lastPosition!.longitude.toStringAsFixed(6)}\n'
                        'Speed: ${_lastPosition!.speed.toStringAsFixed(2)} m/s',
                      ),
                      trailing: Text(
                        _lastPublish?.toLocal().toIso8601String() ?? '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                if (_errorMessage != null)
                  Card(
                    color:
                        Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.warning,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      title: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onErrorContainer,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboardType,
    bool obscureText = false,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
