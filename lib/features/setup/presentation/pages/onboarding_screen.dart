import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import 'package:sgtp_flutter/features/setup/application/viewmodels/onboarding_cubit.dart';
import 'package:sgtp_flutter/features/setup/application/viewmodels/onboarding_view_state.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _serverCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController(text: 'Account');
  final _usernameCtrl = TextEditingController();
  final _picker = ImagePicker();

  OnboardingCubit get _cubit => context.read<OnboardingCubit>();

  @override
  void dispose() {
    _serverCtrl.dispose();
    _nicknameCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    Uint8List? bytes;

    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (file != null) {
      bytes = await file.readAsBytes();
    }

    if ((bytes == null || bytes.isEmpty) && kIsWeb) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final data = (picked != null && picked.files.isNotEmpty)
          ? picked.files.first.bytes
          : null;
      if (data != null && data.isNotEmpty) {
        bytes = data;
      }
    }

    if (bytes == null || bytes.isEmpty) return;
    if (!mounted) return;
    _cubit.setAvatar(bytes);
  }

  Future<void> _restoreFromBackup() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const ['sgtpbackup', 'json'],
      );
      if (picked == null || picked.files.isEmpty) return;
      final bytes = picked.files.first.bytes;
      await _cubit.restoreFromBackup(bytes);
    } catch (_) {
      // FilePicker cancellation — no action needed.
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<OnboardingCubit, OnboardingViewState>(
      listener: (context, state) {
        if (state.completed) {
          if (state.isRestoring) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Backup restored')),
            );
          }
          Navigator.of(context).pop(true);
        }
      },
      builder: (context, state) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    state.step == 0 ? 'Choose Server' : 'Set Up Profile',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.step == 0
                        ? 'First, connect to a working server.'
                        : 'Now set your profile. Username is optional.',
                    style:
                        const TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: state.step == 0
                        ? _buildServerStep(state)
                        : _buildProfileStep(state),
                  ),
                  if (state.error != null) ...[
                    const SizedBox(height: 8),
                    Text(state.error!,
                        style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed:
                        state.isVerifying || state.isSaving || state.isRestoring
                            ? null
                            : (state.step == 0
                                ? () =>
                                    _cubit.verifyServer(_serverCtrl.text)
                                : () => _cubit.finish(
                                    _nicknameCtrl.text, _usernameCtrl.text)),
                    child: state.isVerifying || state.isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(state.step == 0 ? 'Continue' : 'Start'),
                  ),
                  if (state.step == 0) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: state.isVerifying ||
                              state.isSaving ||
                              state.isRestoring
                          ? null
                          : _restoreFromBackup,
                      icon: state.isRestoring
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.restore),
                      label: const Text('Restore from backup'),
                    ),
                  ],
                  if (state.step == 1) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: state.isVerifying || state.isSaving
                          ? null
                          : _cubit.goBackToServerStep,
                      child: const Text('Back to server'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildServerStep(OnboardingViewState state) {
    final available = state.availableTransportsLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _serverCtrl,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'example.com or example.com:443',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (available != null && available.isNotEmpty)
          Text(
            'Detected transports: $available',
            style: const TextStyle(color: Colors.white70),
          ),
      ],
    );
  }

  Widget _buildProfileStep(OnboardingViewState state) {
    return ListView(
      children: [
        if (state.resolvedHost != null && state.resolvedPort != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Server: ${state.resolvedHost}:${state.resolvedPort}',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        Center(
          child: GestureDetector(
            onTap: _pickAvatar,
            child: CircleAvatar(
              radius: 46,
              backgroundImage: state.avatarBytes != null
                  ? MemoryImage(state.avatarBytes!)
                  : null,
              child: state.avatarBytes == null
                  ? const Icon(Icons.add_a_photo_outlined, size: 28)
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _nicknameCtrl,
          decoration: const InputDecoration(
            labelText: 'Nickname',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _usernameCtrl,
          decoration: const InputDecoration(
            labelText: 'Username (optional)',
            hintText: '@alice',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
