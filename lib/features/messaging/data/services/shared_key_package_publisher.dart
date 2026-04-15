import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';

class SharedKeyPackagePublisher implements KeyPackagePublisher {
  SharedKeyPackagePublisher({
    required SgtpConnectionService connectionService,
  });

  final _log = AppLog('SharedKeyPackagePublisher');

  @override
  Future<void> ensureUploaded(SgtpConfig config) async {
    _log.debug(
      'Skipping shell-level MLS key package upload; active chat sessions publish receive-capable key packages',
    );
  }

  @override
  void invalidateForConfig(SgtpConfig config) {}
}
