import 'package:material_ui/material_ui.dart';

/// One-time API credentials entry (on this device only).
///
/// The values are written to secure storage and are never displayed
/// after saving. The form shows only whether credentials are saved.
/// The fields are cleared after saving.
class CredentialsForm extends StatefulWidget {
  const CredentialsForm({
    super.key,
    required this.credentialsSaved,
    required this.onSave,
  });

  final bool credentialsSaved;
  final Future<void> Function(int apiId, String apiHash) onSave;

  @override
  State<CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends State<CredentialsForm> {
  final _apiIdController = TextEditingController();
  final _apiHashController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _apiIdController.dispose();
    _apiHashController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final apiId = int.tryParse(_apiIdController.text.trim());
    final apiHash = _apiHashController.text.trim();
    if (apiId == null || apiHash.isEmpty) {
      setState(() => _error = 'Enter a numeric api_id and an api_hash.');
      return;
    }
    setState(() => _error = null);
    await widget.onSave(apiId, apiHash);
    _apiIdController.clear();
    _apiHashController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'API credentials: ${widget.credentialsSaved ? 'saved' : 'not saved'}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _apiIdController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'api_id',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _apiHashController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'api_hash',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: _save, child: const Text('Save credentials')),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ],
    );
  }
}
