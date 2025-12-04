import 'package:flutter/material.dart';

class MqttSettingsPage extends StatefulWidget {
  const MqttSettingsPage({
    super.key,
    required this.deviceIdController,
    required this.userController,
    required this.brokerController,
    required this.portController,
    required this.topicController,
    required this.clientIdController,
    required this.usernameController,
    required this.passwordController,
    this.hideConnectionFields = false,
  });

  final TextEditingController deviceIdController;
  final TextEditingController userController;
  final TextEditingController brokerController;
  final TextEditingController portController;
  final TextEditingController topicController;
  final TextEditingController clientIdController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool hideConnectionFields;

  @override
  State<MqttSettingsPage> createState() => _MqttSettingsPageState();
}

class _MqttSettingsPageState extends State<MqttSettingsPage> {
  final _formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _buildField(
        controller: widget.deviceIdController,
        label: 'Device ID',
        validator: _requiredValidator,
      ),
      _buildField(
        controller: widget.userController,
        label: 'User',
        hint: 'Diisi otomatis dari nama perangkat',
        enabled: false,
      ),
    ];

    if (widget.hideConnectionFields) {
      children.addAll([
        Card(
          child: ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('Pengaturan MQTT dikunci'),
            subtitle: const Text(
              'Broker, port, topic, username, dan password diatur otomatis oleh server.',
            ),
          ),
        ),
        const SizedBox(height: 16),
      ]);
    } else {
      children.addAll([
        _buildField(
          controller: widget.brokerController,
          label: 'MQTT Broker',
          hint: 'contoh: test.mosquitto.org',
          validator: _requiredValidator,
        ),
        _buildField(
          controller: widget.portController,
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
        _buildField(
          controller: widget.topicController,
          label: 'Topic',
          hint: 'contoh: devices/mobile_tracker',
          validator: _requiredValidator,
        ),
        _buildField(
          controller: widget.clientIdController,
          label: 'Client ID',
          hint: 'Opsional, otomatis jika dikosongkan',
        ),
        _buildField(
          controller: widget.usernameController,
          label: 'Username (opsional)',
        ),
        _buildField(
          controller: widget.passwordController,
          label: 'Password (opsional)',
          obscureText: true,
        ),
        const SizedBox(height: 16),
      ]);
    }

    children.add(
      FilledButton.icon(
        onPressed: _handleSave,
        icon: const Icon(Icons.save),
        label: const Text('Simpan'),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pengaturan MQTT'),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboardType,
    bool obscureText = false,
    bool enabled = true,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        enabled: enabled,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Kolom ini wajib diisi';
    }
    return null;
  }

  void _handleSave() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(true);
  }
}
