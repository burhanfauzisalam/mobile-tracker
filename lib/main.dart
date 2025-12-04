import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'background_service.dart';
import 'mqtt_settings_page.dart';

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
  final _deviceIdController = TextEditingController(text: 'android-001');
  final _userController = TextEditingController(text: 'mobile-device');
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
  bool _autoStartScheduled = false;
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
    _scheduleAutoStart();
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

  bool _hasValidMqttConfig() {
    return _deviceIdController.text.trim().isNotEmpty &&
        _userController.text.trim().isNotEmpty &&
        _brokerController.text.trim().isNotEmpty &&
        _portController.text.trim().isNotEmpty &&
        _topicController.text.trim().isNotEmpty;
  }

  void _scheduleAutoStart() {
    if (_autoStartScheduled) return;
    _autoStartScheduled = true;
    Future.microtask(() async {
      await _populateUserFromDevice();
      if (!_hasValidMqttConfig()) return;
      await _startStreaming();
    });
  }

  Future<void> _populateUserFromDevice() async {
    const fallback = 'mobile-device';
    if (kIsWeb) {
      _userController.text = fallback;
      return;
    }
    try {
      final deviceInfo = DeviceInfoPlugin();
      String? resolved;
      String sanitize(String? value) => value?.trim() ?? '';
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final info = await deviceInfo.androidInfo;
          final manufacturer = sanitize(info.manufacturer);
          final model = sanitize(info.model);
          final fallbackId = sanitize(info.device).isNotEmpty
              ? sanitize(info.device)
              : sanitize(info.id);
          final pieces = <String>[
            if (manufacturer.isNotEmpty) manufacturer,
            if (model.isNotEmpty) model,
          ];
          resolved = pieces.join(' ').trim();
          if (resolved.isEmpty) {
            resolved = fallbackId.isNotEmpty ? fallbackId : fallback;
          }
          break;
        case TargetPlatform.iOS:
          final info = await deviceInfo.iosInfo;
          resolved = sanitize(info.name);
          if (resolved.isEmpty) {
            resolved = sanitize(info.utsname.machine);
          }
          break;
        default:
          resolved = defaultTargetPlatform.name;
          break;
      }
      if (!mounted) return;
      _userController.text =
          (resolved == null || resolved.isEmpty) ? fallback : resolved;
    } catch (_) {
      if (!mounted) return;
      _userController.text = fallback;
    }
  }

  Future<void> _openMqttSettings() async {
    await _navigateWithLoading(() async {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => MqttSettingsPage(
            deviceIdController: _deviceIdController,
            userController: _userController,
            brokerController: _brokerController,
            portController: _portController,
            topicController: _topicController,
            clientIdController: _clientIdController,
            usernameController: _usernameController,
            passwordController: _passwordController,
          ),
        ),
      );
    });
    if (!mounted) return;
    setState(() {});
    if (_hasValidMqttConfig()) {
      await _startStreaming();
    }
  }

  Future<void> _navigateWithLoading(Future<void> Function() action) async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _LoadingDialog(),
    );
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await action();
  }

  Widget _buildMqttSettingsCard() {
    final broker = _brokerController.text.trim();
    final port = _portController.text.trim();
    final topic = _topicController.text.trim();
    final clientId = _clientIdController.text.trim();
    final subtitle = [
      'Broker: ${broker.isEmpty ? '-' : broker}',
      'Port: ${port.isEmpty ? '1883' : port}',
      'Topic: ${topic.isEmpty ? '-' : topic}',
      'Client ID: ${clientId.isEmpty ? 'auto' : clientId}',
    ].join('\n');
    return Card(
      child: ListTile(
        leading: const Icon(Icons.settings_input_antenna),
        title: const Text('Pengaturan MQTT'),
        subtitle: Text(subtitle),
      ),
    );
  }

  Widget _buildStreamingInfoCard() {
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.play_circle_fill,
          color: _isStreaming ? Colors.green : Colors.orange,
        ),
        title: const Text('Streaming lokasi berjalan otomatis'),
        subtitle: Text(
          _isStreaming
              ? 'Layanan background aktif dan mengirim lokasi.'
              : 'Menunggu layanan background...',
        ),
      ),
    );
  }
  Drawer _buildNavigationDrawer() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
          children: [
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('Home'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
              },
              selected: true,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Setting'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                Navigator.of(context).pop();
                await _openMqttSettings();
              },
            ),
          ],
        ),
      ),
    );
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
      drawer: _buildNavigationDrawer(),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildMqttSettingsCard(),
              const SizedBox(height: 12),
              _buildStreamingInfoCard(),
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
                      color:
                          Theme.of(context).colorScheme.onErrorContainer,
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
    );
  }
}

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog();

  @override
  Widget build(BuildContext context) {
    return const Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Loading...'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
