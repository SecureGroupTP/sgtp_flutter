import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';

void main() {
  group('HomeUserDirSupportService', () {
    test('matches server profile completion rule', () {
      final service = HomeUserDirSupportService();

      expect(service.isProfileComplete(''), isFalse);
      expect(service.isProfileComplete('   '), isFalse);
      expect(service.isProfileComplete('Alice'), isTrue);
      expect(service.isProfileComplete(' Alice '), isTrue);
    });
  });
}
