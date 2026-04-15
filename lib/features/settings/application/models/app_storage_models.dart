class AppStorageBreakdown {
  final int totalBytes;
  final int persistentBytes;
  final int tempBytes;

  final int mediaImagesBytes;
  final int mediaVideosBytes;
  final int mediaOtherBytes;

  final int chatHistoryBytes;
  final int chatMetadataBytes;

  final int mlsStateBytes;

  final int accountsOtherBytes;
  final int sharedSgtpBytes;
  final int docsOtherBytes;

  final int appSupportBytes;
  final int tempArtifactsBytes;

  const AppStorageBreakdown({
    required this.totalBytes,
    required this.persistentBytes,
    required this.tempBytes,
    required this.mediaImagesBytes,
    required this.mediaVideosBytes,
    required this.mediaOtherBytes,
    required this.chatHistoryBytes,
    required this.chatMetadataBytes,
    required this.mlsStateBytes,
    required this.accountsOtherBytes,
    required this.sharedSgtpBytes,
    required this.docsOtherBytes,
    required this.appSupportBytes,
    required this.tempArtifactsBytes,
  });
}

