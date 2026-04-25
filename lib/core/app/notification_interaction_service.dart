import 'package:sgtp_flutter/core/app/app_session_controller.dart';

class NotificationInteractionService {
  AppSessionController? _sessionController;

  void attach(AppSessionController controller) {
    _sessionController = controller;
  }

  void detach(AppSessionController controller) {
    if (identical(_sessionController, controller)) {
      _sessionController = null;
    }
  }

  Future<void> openDirectMessage(String peerPubkeyHex) async {
    final controller = _sessionController;
    if (controller == null) {
      return;
    }
    await controller.openDirectMessage(peerPubkeyHex);
  }
}
