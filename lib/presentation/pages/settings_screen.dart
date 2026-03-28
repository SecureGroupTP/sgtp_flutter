import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  final Set<String> whitelist;
  final ValueChanged<Set<String>> onWhitelistChanged;

  const SettingsScreen({
    Key? key,
    required this.whitelist,
    required this.onWhitelistChanged,
  }) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Set<String> _whitelist;

  @override
  void initState() {
    super.initState();
    _whitelist = Set.from(widget.whitelist);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
      ),
      body: ListView(
        children: [
          // Whitelist section
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Peer Whitelist',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only these peer public keys can connect to your chats.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _whitelist.isEmpty
                ? _buildEmptyWhitelist()
                : _buildWhitelistList(),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: _showAddPeerDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add Peer'),
            ),
          ),
          const Divider(height: 32),
          // About section
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'About',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                _buildInfoRow('App Version', '1.0.0'),
                _buildInfoRow('Protocol', 'SGTP v1'),
                _buildInfoRow('Platform', _getPlatformName()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyWhitelist() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.person_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            const Text(
              'No peers in whitelist',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            const Text(
              'Add peers to allow them to connect',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWhitelistList() {
    return Column(
      children: _whitelist.map((pubKey) {
        return _buildWhitelistTile(pubKey);
      }).toList(),
    );
  }

  Widget _buildWhitelistTile(String pubKey) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const CircleAvatar(
          child: Icon(Icons.person),
        ),
        title: Text(
          pubKey.substring(0, 16),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        subtitle: SelectableText(
          pubKey,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete, color: Colors.red),
          onPressed: () {
            setState(() {
              _whitelist.remove(pubKey);
              widget.onWhitelistChanged(_whitelist);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Peer removed')),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  void _showAddPeerDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Peer to Whitelist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Peer Public Key (hex)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Paste the peer\'s public key here',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final pubKey = controller.text.trim().toUpperCase();
              if (pubKey.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a public key')),
                );
                return;
              }

              if (_whitelist.contains(pubKey)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Peer already in whitelist')),
                );
                return;
              }

              setState(() {
                _whitelist.add(pubKey);
                widget.onWhitelistChanged(_whitelist);
              });

              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Peer added')),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  String _getPlatformName() {
    // This would typically use dart:io to detect platform
    // For now, just return a placeholder
    return 'Flutter App';
  }
}
