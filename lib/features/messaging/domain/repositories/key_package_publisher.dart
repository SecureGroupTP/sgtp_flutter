import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

abstract class KeyPackagePublisher {
  Future<void> ensureUploaded(SgtpConfig config);

  void invalidateForConfig(SgtpConfig config);
}
