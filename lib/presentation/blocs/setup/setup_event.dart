import 'package:equatable/equatable.dart';

import '../../../core/sgtp_transport.dart';

abstract class SetupEvent extends Equatable {
  const SetupEvent();
  @override
  List<Object?> get props => [];
}

class SetupLoadData extends SetupEvent {
  const SetupLoadData();
}

class SetupServerAddressChanged extends SetupEvent {
  final String address;
  const SetupServerAddressChanged(this.address);
  @override
  List<Object?> get props => [address];
}

class SetupPickPrivateKey extends SetupEvent {
  const SetupPickPrivateKey();
}

/// Pick a FOLDER of .pub files (all valid ed25519 public keys are loaded).
class SetupPickWhitelistFolder extends SetupEvent {
  const SetupPickWhitelistFolder();
}

/// Pick individual .pub files.
class SetupPickWhitelistFiles extends SetupEvent {
  const SetupPickWhitelistFiles();
}

class SetupTransportChanged extends SetupEvent {
  final SgtpTransportFamily transport;
  const SetupTransportChanged(this.transport);
  @override
  List<Object?> get props => [transport];
}

class SetupTlsChanged extends SetupEvent {
  final bool useTls;
  const SetupTlsChanged(this.useTls);
  @override
  List<Object?> get props => [useTls];
}

class SetupFetchServerOptions extends SetupEvent {
  const SetupFetchServerOptions();
}

class SetupConnect extends SetupEvent {
  const SetupConnect();
}

/// Clear the connectionConfig after navigation so we don't re-navigate on rebuild.
class SetupClearConnection extends SetupEvent {
  const SetupClearConnection();
}
