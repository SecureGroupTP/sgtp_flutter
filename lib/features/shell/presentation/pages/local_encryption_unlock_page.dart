import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/storage/local_encryption_service.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';

class LocalEncryptionUnlockPage extends StatefulWidget {
  const LocalEncryptionUnlockPage({
    super.key,
    required this.settings,
    required this.state,
  });

  final SettingsManagementService settings;
  final LocalEncryptionState state;

  @override
  State<LocalEncryptionUnlockPage> createState() =>
      _LocalEncryptionUnlockPageState();
}

class _LocalEncryptionUnlockPageState extends State<LocalEncryptionUnlockPage> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty) {
      setState(() => _errorText = 'Enter your secret');
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      await widget.settings.unlockLocalEncryption(raw);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _errorText = e.message);
    } on LocalEncryptionAuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorText = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorText = 'Failed to unlock local data');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPassphrase = widget.state.mode == LocalEncryptionSecretMode.passphrase;
    final title = isPassphrase ? 'Unlock with passphrase' : 'Unlock with password';
    final helper = isPassphrase
        ? 'Only letters matter. Spaces, digits and punctuation are ignored.'
        : 'Use the same password you set in Data settings.';

    return Scaffold(
      appBar: AppBar(title: const Text('Local Encryption')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  helper,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  obscureText: !isPassphrase,
                  enableSuggestions: false,
                  autocorrect: false,
                  onSubmitted: (_) => _submitting ? null : _submit(),
                  decoration: InputDecoration(
                    labelText: isPassphrase ? 'Passphrase' : 'Password',
                    errorText: _errorText,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
