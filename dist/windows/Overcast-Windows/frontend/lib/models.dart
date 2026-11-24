class OvercastFile {
  final String id;
  final String name;
  final String path;
  final String format;
  final int size;
  final String? lastEdited;
  final String? createdAt;
  final String? link;
  final String? sha256;

  const OvercastFile({
    required this.id,
    required this.name,
    required this.path,
    required this.format,
    required this.size,
    this.lastEdited,
    this.createdAt,
    this.link,
    this.sha256,
  });

  String get extension => format.toLowerCase().replaceFirst('.', '');

  bool get isImage => const {
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'
      }.contains(extension);

  bool get isVideo => const {
        'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v',
        'mpeg', 'mpg', '3gp'
      }.contains(extension);

  bool get isAudio => const {
        'mp3', 'wav', 'flac', 'ogg', 'm4a', 'aac', 'opus'
      }.contains(extension);

  bool get isText => const {
        'txt', 'md', 'json', 'xml', 'csv', 'log', 'py', 'js', 'ts',
        'jsx', 'tsx', 'html', 'css', 'scss', 'c', 'cpp', 'h', 'hpp',
        'java', 'kt', 'rs', 'go', 'php', 'rb', 'sh', 'yml', 'yaml'
      }.contains(extension);

  bool get isPdf => extension == 'pdf';

  factory OvercastFile.fromJson(Map<String, dynamic> json) {
    return OvercastFile(
      id: '${json['UniqueID'] ?? ''}',
      name: '${json['FileName'] ?? 'Unnamed'}',
      path: '${json['FilePath'] ?? 'home/'}',
      format: '${json['Format'] ?? 'bin'}',
      size: (json['Size'] as num?)?.toInt() ?? 0,
      lastEdited: json['LastEdited']?.toString(),
      createdAt: json['CreatedAt']?.toString(),
      link: json['Link']?.toString(),
      sha256: json['SHA256']?.toString(),
    );
  }
}

class StorageInfo {
  final int total;
  final int used;
  final int free;

  const StorageInfo({required this.total, required this.used, required this.free});

  double get fraction => total <= 0 ? 0 : used / total;

  factory StorageInfo.fromJson(Map<String, dynamic> json) => StorageInfo(
        total: (json['total'] as num?)?.toInt() ?? 0,
        used: (json['used'] as num?)?.toInt() ?? 0,
        free: (json['free'] as num?)?.toInt() ?? 0,
      );
}

class TrashEntry extends OvercastFile {
  final String lastLocation;
  final String trashedDate;

  const TrashEntry({
    required super.id,
    required super.name,
    required super.path,
    required super.format,
    required super.size,
    super.lastEdited,
    super.createdAt,
    super.link,
    super.sha256,
    required this.lastLocation,
    required this.trashedDate,
  });

  factory TrashEntry.fromJson(Map<String, dynamic> json) => TrashEntry(
        id: '${json['UniqueID'] ?? json['UID'] ?? ''}',
        name: '${json['FileName'] ?? 'Unnamed'}',
        path: '${json['FilePath'] ?? 'Trash/'}',
        format: '${json['Format'] ?? 'bin'}',
        size: (json['Size'] as num?)?.toInt() ?? 0,
        lastEdited: json['LastEdited']?.toString(),
        createdAt: json['CreatedAt']?.toString(),
        link: json['Link']?.toString(),
        sha256: json['SHA256']?.toString(),
        lastLocation: '${json['LastLoc'] ?? 'home/'}',
        trashedDate: '${json['TrashedDate'] ?? ''}',
      );
}

class UploadSessionInfo {
  final String uploadId;
  final String uid;
  final String fileName;
  final String filePath;
  final int totalSize;
  final int chunkSize;
  final int totalChunks;
  final List<int> receivedChunks;
  final List<int> missingChunks;
  final int receivedBytes;
  final bool resumed;
  final String status;

  const UploadSessionInfo({
    required this.uploadId,
    required this.uid,
    required this.fileName,
    required this.filePath,
    required this.totalSize,
    required this.chunkSize,
    required this.totalChunks,
    required this.receivedChunks,
    required this.missingChunks,
    required this.receivedBytes,
    required this.resumed,
    required this.status,
  });

  factory UploadSessionInfo.fromJson(Map<String, dynamic> json) {
    final received = (json['receivedChunks'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    final missing = (json['missingChunks'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    return UploadSessionInfo(
      uploadId: '${json['uploadId'] ?? ''}',
      uid: '${json['uid'] ?? ''}',
      fileName: '${json['fileName'] ?? ''}',
      filePath: '${json['filePath'] ?? 'home/'}',
      totalSize: (json['totalSize'] as num?)?.toInt() ?? 0,
      chunkSize: (json['chunkSize'] as num?)?.toInt() ?? (4 * 1024 * 1024),
      totalChunks: (json['totalChunks'] as num?)?.toInt() ?? 1,
      receivedChunks: received,
      missingChunks: missing,
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      resumed: json['resumed'] == true,
      status: '${json['status'] ?? 'uploading'}',
    );
  }
}

class ChunkUploadResult {
  final String uploadId;
  final int chunkIndex;
  final int size;
  final String sha256;
  final int receivedCount;
  final int totalChunks;

  const ChunkUploadResult({
    required this.uploadId,
    required this.chunkIndex,
    required this.size,
    required this.sha256,
    required this.receivedCount,
    required this.totalChunks,
  });

  factory ChunkUploadResult.fromJson(Map<String, dynamic> json) {
    return ChunkUploadResult(
      uploadId: '${json['uploadId'] ?? ''}',
      chunkIndex: (json['chunkIndex'] as num?)?.toInt() ?? 0,
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: '${json['sha256'] ?? ''}',
      receivedCount: (json['receivedCount'] as num?)?.toInt() ?? 0,
      totalChunks: (json['totalChunks'] as num?)?.toInt() ?? 1,
    );
  }
}

class BulkDeleteResult {
  final String status;
  final int deletedCount;
  final List<String> succeeded;
  final List<Map<String, dynamic>> failed;

  const BulkDeleteResult({
    required this.status,
    required this.deletedCount,
    required this.succeeded,
    required this.failed,
  });

  factory BulkDeleteResult.fromJson(Map<String, dynamic> json) {
    final succ = (json['succeeded'] as List?)
            ?.map((e) => '$e')
            .toList() ??
        const <String>[];
    final fail = (json['failed'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        const <Map<String, dynamic>>[];
    return BulkDeleteResult(
      status: '${json['status'] ?? 'completed'}',
      deletedCount: (json['deletedCount'] as num?)?.toInt() ?? succ.length,
      succeeded: succ,
      failed: fail,
    );
  }
}
