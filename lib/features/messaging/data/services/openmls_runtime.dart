import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:openmls/openmls.dart';
import 'package:path_provider/path_provider.dart';

import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

class OpenMlsRuntimeFactory {
  OpenMlsRuntimeFactory({HashAlgorithm? hashAlgorithm})
      : _hashAlgorithm = hashAlgorithm ?? Sha256();

  final HashAlgorithm _hashAlgorithm;

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
      encryptionKey: await _encryptionKey(
        config: config,
        privateKey: privateKey,
      ),
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
    final accountId = (config.accountId ?? '').trim();
    final publicHex = _hex(config.myPublicKey);
    final addressHash = await _hashHex(utf8.encode(config.serverAddr));
    final name = 'mls_${publicHex.substring(0, 16)}_${addressHash.substring(0, 12)}';
    if (kIsWeb) {
      final accountSegment = accountId.isEmpty ? 'default' : accountId;
      return 'sgtp_${accountSegment}_$name';
    }

    final supportDir = await getApplicationSupportDirectory();
    final base = accountId.isEmpty
        ? '${supportDir.path}/sgtp_mls'
        : '${supportDir.path}/sgtp_accounts/$accountId/sgtp_mls';
    await Directory(base).create(recursive: true);
    return '$base/$name.db';
  }

  Future<Uint8List> _encryptionKey({
    required SgtpConfig config,
    required Uint8List privateKey,
  }) async {
    final builder = BytesBuilder(copy: false)
      ..add(utf8.encode('sgtp-openmls-runtime-v1'))
      ..addByte(0)
      ..add(utf8.encode(config.serverAddr))
      ..addByte(0)
      ..add(utf8.encode(config.accountId ?? ''))
      ..addByte(0)
      ..add(config.myPublicKey)
      ..addByte(0)
      ..add(privateKey);
    final digest = await _hashAlgorithm.hash(builder.takeBytes());
    return Uint8List.fromList(digest.bytes);
  }

  Future<String> _hashHex(List<int> bytes) async {
    final digest = await _hashAlgorithm.hash(bytes);
    return _hex(digest.bytes);
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
