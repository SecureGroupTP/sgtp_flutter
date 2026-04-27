import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

void main() {
  group('HomeUserDirSupportService', () {
    test('matches server profile completion rule', () {
      final service = HomeUserDirSupportService();

      expect(service.isProfileComplete(''), isFalse);
      expect(service.isProfileComplete('   '), isFalse);
      expect(service.isProfileComplete('Alice'), isTrue);
      expect(service.isProfileComplete(' Alice '), isTrue);
    });

    test('removes pending incoming request after local decline', () {
      final service = HomeUserDirSupportService();
      final peerHex = '01' * 32;

      final next = service.applyLocalFriendResponse(
        previous: {
          peerHex: FriendStateRecord(
            peerPubkeyHex: peerHex,
            status: FriendStatus.pendingIncoming.name,
            roomUUIDHex: null,
            updatedAt: 1,
          ),
        },
        peerHex: peerHex,
        accept: false,
        nowSec: 2,
      );

      expect(next, isNot(contains(peerHex)));
    });

    test('promotes pending incoming request after local accept', () {
      final service = HomeUserDirSupportService();
      final peerHex = '02' * 32;

      final next = service.applyLocalFriendResponse(
        previous: {
          peerHex: FriendStateRecord(
            peerPubkeyHex: peerHex,
            status: FriendStatus.pendingIncoming.name,
            roomUUIDHex: 'room-1',
            updatedAt: 1,
          ),
        },
        peerHex: peerHex,
        accept: true,
        nowSec: 2,
      );

      expect(next[peerHex]?.statusEnum, FriendStatus.friend);
      expect(next[peerHex]?.roomUUIDHex, 'room-1');
      expect(next[peerHex]?.updatedAt, 2);
    });
  });
}
