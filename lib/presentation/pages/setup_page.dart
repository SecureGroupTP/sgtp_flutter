import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/setup/setup_bloc.dart';
import '../blocs/setup/setup_event.dart';
import '../blocs/setup/setup_state.dart';
import '../../data/repositories/settings_repository.dart';
import 'home_screen.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _serverCtrl = TextEditingController();
  final _formKey    = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    context.read<SetupBloc>().add(const SetupLoadData());
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SetupBloc, SetupState>(
      listener: (context, state) {
        if (_serverCtrl.text != state.serverAddress) {
          _serverCtrl.text = state.serverAddress;
          _serverCtrl.selection = TextSelection.fromPosition(
              TextPosition(offset: _serverCtrl.text.length));
        }
        if (state.error != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(state.error!),
              backgroundColor: Theme.of(context).colorScheme.error,
            ));
        }
        if (state.connectionConfig != null) {
          final config    = state.connectionConfig!;
          final nicknames = state.nicknames;
          final server    = state.serverAddress;
          context.read<SetupBloc>().add(const SetupClearConnection());
          // Navigate to HomeScreen, replacing setup
          unawaited(() async {
            final settings = SettingsRepository();
            final preferred = await settings.loadPreferredNode();
            final accountId = preferred?.id ?? '';
            final entries = accountId.trim().isEmpty
                ? await settings.loadWhitelistEntries()
                : await settings.loadWhitelistEntriesForNode(accountId);
            final avatar = accountId.trim().isEmpty
                ? await settings.loadUserAvatar()
                : await settings.loadUserAvatarForNode(accountId);
            if (!mounted) return;
            Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => HomeScreen(
                accountId: accountId,
                initialConfig: config,
                nicknames: nicknames,
                serverAddress: server,
                userAvatar: avatar,
                initialWhitelist: entries,
              ),
            ));
          }());
        }
      },
      builder: (context, state) {
        return Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 32),
                    _buildHeader(context),
                    const SizedBox(height: 40),
                    _buildServerField(context, state),
                    const SizedBox(height: 16),
                    _buildPrivateKeySection(context, state),
                    const SizedBox(height: 16),
                    _buildWhitelistSection(context, state),
                    const SizedBox(height: 32),
                    _buildConnectButton(context, state),
                    if (state.myPublicKey != null) ...[
                      const SizedBox(height: 24),
                      _buildMyKeyInfo(context, state),
                    ],
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      Icon(Icons.lock_outline, size: 64, color: theme.colorScheme.primary),
      const SizedBox(height: 16),
      Text('SGTP Chat', style: theme.textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
      const SizedBox(height: 8),
      Text('Secure Group Transfer Protocol',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }

  Widget _buildServerField(BuildContext context, SetupState state) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: state.serverAddress),
      optionsBuilder: (v) => v.text.isEmpty
          ? state.savedAddresses
          : state.savedAddresses.where((a) => a.contains(v.text)),
      onSelected: (v) => context.read<SetupBloc>().add(SetupServerAddressChanged(v)),
      fieldViewBuilder: (ctx, ctrl, fn, onSubmitted) {
        if (ctrl.text != state.serverAddress && state.serverAddress.isNotEmpty) {
          ctrl.text = state.serverAddress;
        }
        return TextFormField(
          controller: ctrl, focusNode: fn,
          decoration: const InputDecoration(
            labelText: 'Server address', hintText: 'host:7777',
            prefixIcon: Icon(Icons.dns_outlined), border: OutlineInputBorder(),
          ),
          onChanged: (v) => context.read<SetupBloc>().add(SetupServerAddressChanged(v)),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        );
      },
    );
  }

  Widget _buildPrivateKeySection(BuildContext context, SetupState state) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12), side: BorderSide(color: theme.colorScheme.outline)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Private key', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Your ed25519 private key file (OpenSSH format)',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(state.privateKeyPath ?? 'No file selected',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: state.privateKeyPath != null
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: state.isLoading
                  ? null
                  : () => context.read<SetupBloc>().add(const SetupPickPrivateKey()),
              icon: const Icon(Icons.file_open_outlined), label: const Text('Browse'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildWhitelistSection(BuildContext context, SetupState state) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12), side: BorderSide(color: theme.colorScheme.outline)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Trusted peers (whitelist)', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Folder or files with .pub keys.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (state.whitelistPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 4, children: state.whitelistPaths.map((p) {
              var nick = p;
              if (nick.toLowerCase().endsWith('.pub')) nick = nick.substring(0, nick.length - 4);
              return Chip(label: Text(nick, style: theme.textTheme.labelSmall),
                  visualDensity: VisualDensity.compact, padding: EdgeInsets.zero);
            }).toList()),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: FilledButton.tonalIcon(
              onPressed: state.isLoading
                  ? null
                  : () => context.read<SetupBloc>().add(const SetupPickWhitelistFolder()),
              icon: const Icon(Icons.folder_open_outlined), label: const Text('Folder'),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(
              onPressed: state.isLoading
                  ? null
                  : () => context.read<SetupBloc>().add(const SetupPickWhitelistFiles()),
              icon: const Icon(Icons.file_present_outlined), label: const Text('Files'),
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _buildConnectButton(BuildContext context, SetupState state) {
    return FilledButton.icon(
      onPressed: state.isLoading || !state.isReadyToConnect
          ? null
          : () => context.read<SetupBloc>().add(const SetupConnect()),
      icon: state.isLoading
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.login),
      label: Text(state.isLoading ? 'Loading…' : 'Continue'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
    );
  }

  Widget _buildMyKeyInfo(BuildContext context, SetupState state) {
    final theme  = Theme.of(context);
    final pubHex = state.myPublicKey!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return Card(
      color: theme.colorScheme.secondaryContainer, elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Text('Your public key (share with peers)',
                style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(pubHex,
                style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace', color: theme.colorScheme.onSecondaryContainer))),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: pubHex));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Public key copied')));
              },
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ]),
        ]),
      ),
    );
  }
}
