import 'package:sgtp_flutter/features/messaging/data/services/server_v2_chat_session.dart';

export 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';

const String kLegacySgtpClientDeprecationMessage =
    'Legacy class name. Use ServerV2ChatSession for the active OpenMLS-backed '
    'chat runtime.';

typedef OpenMlsChatSession = ServerV2ChatSession;

@Deprecated(kLegacySgtpClientDeprecationMessage)
typedef SgtpClient = ServerV2ChatSession;
