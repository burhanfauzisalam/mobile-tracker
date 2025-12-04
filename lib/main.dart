import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'background_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await initializeBackgroundService();
  }
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
      TextEditingController(text: 'tracking/android/android-002/location');
  final _clientIdController = TextEditingController(
    text: 'mobile-tracker-${DateTime.now().millisecondsSinceEpoch}',
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();
  StreamSubscription<dynamic>? _statusSubscription;
  StreamSubscription<dynamic>? _payloadSubscription;

  bool _isStreaming = false;
  String _status = 'Disconnected';
  String? _errorMessage;
  String? _activeTopic;
  DateTime? _lastPublish;
  double? _lastLatitude;
  double? _lastLongitude;
  double? _lastSpeed;
  int? _lastBattery;

  @override
  void initState() {
    super.initState();
    _setupServiceListeners();
    _syncServiceState();
  }

  Future<void> _syncServiceState() async {
    final running = await _backgroundService.isRunning();
    if (!mounted) return;
    setState(() {
      _isStreaming = running;
      _status = running
          ? 'Background service aktif'
          : 'Disconnected';
    });
  }

  void _setupServiceListeners() {
    _statusSubscription ??=
        _backgroundService.on('status').listen((event) {
      if (event == null || !mounted) return;
      final status = event['status']?.toString() ?? _status;
      setState(() {
        _status = status;
        if (status.toLowerCase().contains('streaming')) {
          _isStreaming = true;
        }
        if (status.toLowerCase().contains('stopped') ||
            status.toLowerCase().contains('disconnected')) {
          _isStreaming = false;
          _activeTopic = null;
        }
        _errorMessage = event['error']?.toString();
        if (event['topic'] != null) {
          _activeTopic = event['topic'].toString();
        }
      });
    });

    _payloadSubscription ??=
        _backgroundService.on('last_payload').listen((event) {
      if (event == null || !mounted) return;
      setState(() {
        _isStreaming = true;
        _lastLatitude = (event['latitude'] as num?)?.toDouble();
        _lastLongitude = (event['longitude'] as num?)?.toDouble();
        _lastSpeed = (event['speed'] as num?)?.toDouble();
        _lastBattery = (event['battery'] as num?)?.toInt();
        final ts = event['timestamp'];
        if (ts is int) {
          _lastPublish = DateTime.fromMillisecondsSinceEpoch(
            ts * 1000,
            isUtc: true,
          ).toLocal();
        } else if (ts is String) {
          _lastPublish = DateTime.tryParse(ts);
        }
        if (event['topic'] != null) {
          _activeTopic = event['topic'].toString();
        }
      });
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _payloadSubscription?.cancel();
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
    if (_isStreaming || await _backgroundService.isRunning()) {
      await _stopStreaming();
    } else {
      final isValid = _formKey.currentState?.validate() ?? false;
      if (!isValid) return;
      await _startStreaming();
    }
  }

  Future<void> _startStreaming() async {
    FocusScope.of(context).unfocus();
    if (kIsWeb) {
      setState(() {
        _status = 'Layanan background tidak tersedia di Web';
        _errorMessage = 'Jalankan aplikasi di perangkat Android/iOS.';
      });
      return;
    }
    setState(() {
      _status = 'Checking GPS permission...';
      _errorMessage = null;
    });

    try {
      await _ensureLocationPermission();
      await _ensureNotificationPermission();
    } catch (error) {
      setState(() {
        _status = 'Permission error';
        _errorMessage = error.toString();
      });
      return;
    }

    _setupServiceListeners();
    final running = await _backgroundService.isRunning();
    if (!running) {
      await _backgroundService.startService();
    }
    final config = _buildServiceConfig();
    _backgroundService.invoke('config', config);

    setState(() {
      _isStreaming = true;
      _status = 'Starting background service...';
      _activeTopic = config['topic']?.toString();
    });
  }

  Future<void> _stopStreaming() async {
    _backgroundService.invoke('stopService');
    setState(() {
      _isStreaming = false;
      _status = 'Disconnected';
      _activeTopic = null;
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
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.always) {
      throw Exception(
        'Izin lokasi "Allow all the time" diperlukan untuk tracking background.',
      );
    }
  }

  Future<void> _ensureNotificationPermission() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final status = await Permission.notification.status;
    if (status.isGranted || status.isLimited) {
      return;
    }
    final result = await Permission.notification.request();
    if (!result.isGranted) {
      throw Exception(
        'Izin notifikasi diperlukan agar layanan foreground dapat berjalan.',
      );
    }
  }

  Map<String, dynamic> _buildServiceConfig() {
    final port = int.tryParse(_portController.text.trim()) ?? 1883;
    return {
      'device_id': _deviceIdController.text.trim(),
      'user': _userController.text.trim(),
      'broker': _brokerController.text.trim(),
      'port': port,
      'topic': _topicController.text.trim(),
      'client_id': _clientIdText,
      'username': _usernameController.text.trim(),
      'password': _passwordController.text,
      'interval_seconds': 15,
    };
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
                    subtitle: Text(
                      _activeTopic == null
                          ? _status
                          : '$_status\nTopic: $_activeTopic',
                    ),
                  ),
                ),
                if (_lastLatitude != null && _lastLongitude != null)
                  Card(
                    child: ListTile(
                      title: const Text('Data GPS terakhir'),
                      subtitle: Text(
                        'Lat: ${_lastLatitude!.toStringAsFixed(6)}\n'
                        'Lng: ${_lastLongitude!.toStringAsFixed(6)}\n'
                        'Speed: ${(_lastSpeed ?? 0).toStringAsFixed(2)} m/s\n'
                        'Battery: ${_lastBattery ?? 0}%',
                      ),
                      trailing: Text(
                        _lastPublish?.toLocal().toIso8601String() ?? '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                if (_errorMessage != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.warning,
                        color: Theme.of(context)
                            .colorScheme
                            .onErrorContainer,
                      ),
                      subtitle: Text(
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
