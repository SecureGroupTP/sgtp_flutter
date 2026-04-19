import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';
import 'package:sgtp_flutter/core/storage/storage_key_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

class OpenMlsRuntimeFactory {
  OpenMlsRuntimeFactory({
    required AccountStoragePaths accountStoragePaths,
    required StorageKeyService storageKeyService,
  })  : _accountStoragePaths = accountStoragePaths,
        _storageKeyService = storageKeyService;

  final AccountStoragePaths _accountStoragePaths;
  final StorageKeyService _storageKeyService;

  Future<OpenMlsRuntime> create(SgtpConfig config) async {
    final publicKey = Uint8List.fromList(config.myPublicKey);
    final privateKey = Uint8List.fromList(
      await config.identityKeyPair.extractPrivateKeyBytes(),
    );
    final signerBytes = serializeSigner(
      ciphersuite: OpenMlsRuntime.ciphersuite,
      privateKey: privateKey,
      publicKey: publicKey,
    );
    final engine = await MlsEngine.create(
      dbPath: await _dbPath(config),
      encryptionKey: await _encryptionKey(config),
    );
    return OpenMlsRuntime(
      engine: engine,
      signerBytes: signerBytes,
      signerPublicKey: publicKey,
      credentialIdentity: publicKey,
      groupConfig: MlsGroupConfig.defaultConfig(
        ciphersuite: OpenMlsRuntime.ciphersuite,
      ),
    );
  }

  Future<String> _dbPath(SgtpConfig config) async {
    final layout = await _accountStoragePaths.resolve(config.accountId ?? '');
    return layout.mlsDatabasePath;
  }

  Future<Uint8List> _encryptionKey(SgtpConfig config) =>
      _storageKeyService.loadOrCreateAccountKey(config.accountId ?? '');
}

class OpenMlsRuntime {
  OpenMlsRuntime({
    required this.engine,
    required this.signerBytes,
    required this.signerPublicKey,
    required this.credentialIdentity,
    required this.groupConfig,
  });

  static const ciphersuite =
      MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

  final MlsEngine engine;
  final Uint8List signerBytes;
  final Uint8List signerPublicKey;
  final Uint8List credentialIdentity;
  final MlsGroupConfig groupConfig;

  Future<bool> hasGroup(Uint8List groupId) async {
    try {
      return await engine.groupIsActive(groupIdBytes: groupId);
    } catch (_) {
      return false;
    }
  }

  Future<void> createGroup(Uint8List groupId) async {
    await engine.createGroup(
      config: groupConfig,
      signerBytes: signerBytes,
      credentialIdentity: credentialIdentity,
      signerPublicKey: signerPublicKey,
      groupId: groupId,
    );
  }

  Future<OpenMlsRoomState> exportRoomState(Uint8List groupId) async {
    final context = await engine.exportGroupContext(groupIdBytes: groupId);
    final epoch = await engine.groupEpoch(groupIdBytes: groupId);
    final treeBytes = await engine.exportRatchetTree(groupIdBytes: groupId);
    return OpenMlsRoomState(
      groupId: context.groupId,
      epoch: epoch.toInt(),
      treeBytes: treeBytes,
      treeHash: context.treeHash,
    );
  }

  Future<OpenMlsInviteResult> addMember({
    required Uint8List groupId,
    required Uint8List keyPackageBytes,
  }) async {
    final result = await engine.addMembers(
      groupIdBytes: groupId,
      signerBytes: signerBytes,
      keyPackagesBytes: <Uint8List>[keyPackageBytes],
    );
    return OpenMlsInviteResult(
      commit: result.commit,
      welcome: result.welcome,
      groupInfo: result.groupInfo,
    );
  }

  Future<void> mergePendingCommit(Uint8List groupId) {
    return engine.mergePendingCommit(groupIdBytes: groupId);
  }

  Future<Uint8List> createMessage({
    required Uint8List groupId,
    required Uint8List plaintext,
    Uint8List? aad,
  }) async {
    final result = await engine.createMessage(
      groupIdBytes: groupId,
      signerBytes: signerBytes,
      message: plaintext,
      aad: aad,
    );
    return result.ciphertext;
  }

  Future<void> joinFromWelcome(Uint8List welcomeBytes) {
    return engine.joinGroupFromWelcome(
      config: groupConfig,
      welcomeBytes: welcomeBytes,
      signerBytes: signerBytes,
    );
  }

  Future<OpenMlsProcessedIncoming> processIncoming({
    required Uint8List groupId,
    required Uint8List messageBytes,
  }) async {
    final result = await engine.processMessage(
      groupIdBytes: groupId,
      messageBytes: messageBytes,
    );
    final shouldMerge = result.messageType == ProcessedMessageType.stagedCommit ||
        result.hasStagedCommit;
    if (shouldMerge) {
      await engine.mergePendingCommit(groupIdBytes: groupId);
    }
    return OpenMlsProcessedIncoming(
      messageType: result.messageType,
      applicationMessage: result.applicationMessage,
      hasProposal: result.hasProposal,
      hasStagedCommit: result.hasStagedCommit,
      proposalType: result.proposalType,
    );
  }

  Future<void> dropGroup(Uint8List groupId) {
    return engine.deleteGroup(groupIdBytes: groupId);
  }

  Future<List<Uint8List>> createKeyPackages(
    int count, {
    bool lastResort = false,
    Duration lifetime = const Duration(days: 30),
  }) async {
    final options = KeyPackageOptions(
      lifetimeSeconds: BigInt.from(lifetime.inSeconds),
      lastResort: lastResort,
    );
    final out = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final result = await engine.createKeyPackageWithOptions(
        ciphersuite: ciphersuite,
        signerBytes: signerBytes,
        credentialIdentity: credentialIdentity,
        signerPublicKey: signerPublicKey,
        options: options,
      );
      out.add(result.keyPackageBytes);
    }
    return out;
  }

  Future<void> close() => engine.close();
}

class OpenMlsRoomState {
  const OpenMlsRoomState({
    required this.groupId,
    required this.epoch,
    required this.treeBytes,
    required this.treeHash,
  });

  final Uint8List groupId;
  final int epoch;
  final Uint8List treeBytes;
  final Uint8List treeHash;
}

class OpenMlsInviteResult {
  const OpenMlsInviteResult({
    required this.commit,
    required this.welcome,
    this.groupInfo,
  });

  final Uint8List commit;
  final Uint8List welcome;
  final Uint8List? groupInfo;
}

class OpenMlsProcessedIncoming {
  const OpenMlsProcessedIncoming({
    required this.messageType,
    this.applicationMessage,
    required this.hasProposal,
    required this.hasStagedCommit,
    this.proposalType,
  });

  final ProcessedMessageType messageType;
  final Uint8List? applicationMessage;
  final bool hasProposal;
  final bool hasStagedCommit;
  final MlsProposalType? proposalType;
}
