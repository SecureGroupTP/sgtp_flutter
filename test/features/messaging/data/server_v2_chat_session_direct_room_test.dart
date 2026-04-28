import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new direct room bootstrap attempts to invite the peer', () {
    final source = File(
      'lib/features/messaging/data/services/server_v2_chat_session.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains('''
    if (_directRoomNeedsBootstrap) {
      await _ensureMlsGroupCreated();
      await _publishRoomState();
      final invited = await _inviteKnownPeers();
'''),
    );
  });
}
