import 'package:equatable/equatable.dart';

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

class SetupPickWhitelistFiles extends SetupEvent {
  const SetupPickWhitelistFiles();
}

class SetupRoomUUIDChanged extends SetupEvent {
  final String uuid;
  const SetupRoomUUIDChanged(this.uuid);
  @override
  List<Object?> get props => [uuid];
}

class SetupConnect extends SetupEvent {
  const SetupConnect();
}
