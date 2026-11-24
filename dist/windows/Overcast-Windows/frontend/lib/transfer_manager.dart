import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api.dart';

enum TransferType {
  upload,
  download,
  bulkDownload,
}

enum TransferState {
  queued,
  preparing,
  uploading,
  downloading,
  paused,
  finalizing,
  completed,
  failed,
  cancelled,
}

class TransferTask {
  final String id;
  final String fileName;
  final TransferType type;
  final String remotePath;
  final String? localSourcePath;
  final String? localTargetPath;
  final String? remoteFileId;
  final List<String> bulkFileIds;
  final List<String> bulkFolderPaths;

  TransferState state;
  int transferredBytes;
  int totalBytes;
  double speedBytesPerSec;
  int? etaSeconds;
  int currentChunk;
  int totalChunks;
  String? uploadSessionId;
  String? errorMessage;
  CancelToken? activeCancelToken;
  bool cancelRequested;
  DateTime startedAt;
  DateTime lastProgressEmit;

  TransferTask({
    required this.id,
    required this.fileName,
    required this.type,
    required this.remotePath,
    this.localSourcePath,
    this.localTargetPath,
    this.remoteFileId,
    this.bulkFileIds = const [],
    this.bulkFolderPaths = const [],
    this.state = TransferState.queued,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.etaSeconds,
    this.currentChunk = 0,
    this.totalChunks = 1,
    this.uploadSessionId,
    this.errorMessage,
  })  : cancelRequested = false,
        startedAt = DateTime.now(),
        lastProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);

  double get progress {
    if (state == TransferState.completed) return 1.0;
    if (totalBytes <= 0) return 0.0;
    return (transferredBytes / totalBytes).clamp(0.0, 1.0);
  }

  bool get isActive =>
      state == TransferState.queued ||
      state == TransferState.preparing ||
      state == TransferState.uploading ||
      state == TransferState.downloading ||
      state == TransferState.finalizing;

  bool get canCancel => isActive || state == TransferState.paused;

  bool get canRetry =>
      state == TransferState.failed || state == TransferState.paused;

  String get stateLabel {
    switch (state) {
      case TransferState.queued:
        return 'Queued';
      case TransferState.preparing:
        return 'Preparing';
      case TransferState.uploading:
        return totalChunks > 1
            ? 'Uploading (${currentChunk + 1}/$totalChunks)'
            : 'Uploading';
      case TransferState.downloading:
        return 'Downloading';
      case TransferState.paused:
        return 'Paused';
      case TransferState.finalizing:
        return 'Finalizing';
      case TransferState.completed:
        return 'Completed';
      case TransferState.failed:
        return 'Failed';
      case TransferState.cancelled:
        return 'Cancelled';
    }
  }
}

class TransferManager extends ChangeNotifier {
  OvercastApi api;
  final Future<void> Function()? onUploadCompleted;
  final void Function(String message, {bool error})? onNotify;

  /// Default chunk size: 4 MiB.
  final int chunkSize;

  /// Files larger than [chunkThresholdBytes] use the multi-chunk upload protocol.
  /// Files at or below [chunkThresholdBytes] also use chunked uploads if > 2 MiB,
  /// or single-request upload for tiny files.
  final int chunkThresholdBytes;

  final int maxConcurrentTransfers;
  final int maxChunkRetries;

  final List<TransferTask> _tasks = [];
  int _activeCount = 0;
  int _counter = 0;
  DateTime _lastUiNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingNotifyTimer;

  TransferManager({
    required this.api,
    this.onUploadCompleted,
    this.onNotify,
    this.chunkSize = 4 * 1024 * 1024,
    this.chunkThresholdBytes = 2 * 1024 * 1024,
    this.maxConcurrentTransfers = 2,
    this.maxChunkRetries = 4,
  });

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  List<TransferTask> get activeTasks =>
      _tasks.where((t) => t.isActive).toList(growable: false);

  int get activeCount => _tasks.where((t) => t.isActive).length;

  double get aggregateProgress {
    final active = activeTasks;
    if (active.isEmpty) return 0.0;
    int total = 0;
    int done = 0;
    for (final t in active) {
      total += math.max(t.totalBytes, 1);
      done += t.transferredBytes;
    }
    return total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
  }

  void updateApi(OvercastApi newApi) {
    api = newApi;
  }

  void _notifyThrottled({bool force = false}) {
    final now = DateTime.now();
    if (force ||
        now.difference(_lastUiNotify) >= const Duration(milliseconds: 110)) {
      _lastUiNotify = now;
      _trailingNotifyTimer?.cancel();
      notifyListeners();
    } else if (_trailingNotifyTimer == null || !_trailingNotifyTimer!.isActive) {
      _trailingNotifyTimer = Timer(const Duration(milliseconds: 120), () {
        _lastUiNotify = DateTime.now();
        notifyListeners();
      });
    }
  }

  String _nextId() {
    _counter++;
    return 'tx_${DateTime.now().millisecondsSinceEpoch}_$_counter';
  }

  TransferTask enqueueUpload({
    required String localFilePath,
    required String fileName,
    required String destinationFolder,
  }) {
    final task = TransferTask(
      id: _nextId(),
      fileName: fileName,
      type: TransferType.upload,
      remotePath: destinationFolder,
      localSourcePath: localFilePath,
      state: TransferState.queued,
    );
    _tasks.insert(0, task);
    _notifyThrottled(force: true);
    _pumpQueue();
    return task;
  }

  TransferTask enqueueDownload({
    required String fileId,
    required String fileName,
    required int totalBytes,
    required String targetFilePath,
  }) {
    final task = TransferTask(
      id: _nextId(),
      fileName: fileName,
      type: TransferType.download,
      remotePath: '',
      remoteFileId: fileId,
      localTargetPath: targetFilePath,
      totalBytes: totalBytes,
      state: TransferState.queued,
    );
    _tasks.insert(0, task);
    _notifyThrottled(force: true);
    _pumpQueue();
    return task;
  }

  TransferTask enqueueBulkDownload({
    required List<String> fileIds,
    required List<String> folderPaths,
    required String basePath,
    required String archiveName,
    required String targetFilePath,
    int estimatedTotalBytes = 0,
  }) {
    final task = TransferTask(
      id: _nextId(),
      fileName: archiveName,
      type: TransferType.bulkDownload,
      remotePath: basePath,
      localTargetPath: targetFilePath,
      bulkFileIds: List.unmodifiable(fileIds),
      bulkFolderPaths: List.unmodifiable(folderPaths),
      totalBytes: estimatedTotalBytes,
      state: TransferState.queued,
    );
    _tasks.insert(0, task);
    _notifyThrottled(force: true);
    _pumpQueue();
    return task;
  }

  Future<void> cancelTransfer(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index < 0) return;
    final task = _tasks[index];
    if (!task.canCancel) return;

    task.cancelRequested = true;
    task.state = TransferState.cancelled;
    task.speedBytesPerSec = 0;
    task.etaSeconds = null;

    final token = task.activeCancelToken;
    task.activeCancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('Cancelled by user');
    }

    _notifyThrottled(force: true);

    if (task.type == TransferType.upload && task.uploadSessionId != null) {
      final sessionId = task.uploadSessionId!;
      try {
        await api.cancelChunkedUpload(sessionId);
      } catch (_) {}
    } else if (task.type == TransferType.download ||
        task.type == TransferType.bulkDownload) {
      await _cleanupPartialDownload(task);
    }
  }

  Future<void> retryTransfer(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index < 0) return;
    final task = _tasks[index];
    if (!task.canRetry) return;

    task.cancelRequested = false;
    task.errorMessage = null;
    task.state = TransferState.queued;
    task.speedBytesPerSec = 0;
    task.etaSeconds = null;
    _notifyThrottled(force: true);
    _pumpQueue();
  }

  void clearFinished() {
    _tasks.removeWhere((t) =>
        t.state == TransferState.completed ||
        t.state == TransferState.cancelled ||
        t.state == TransferState.failed);
    _notifyThrottled(force: true);
  }

  void removeTask(String taskId) {
    _tasks.removeWhere((t) => t.id == taskId && !t.isActive);
    _notifyThrottled(force: true);
  }

  void onAppLifecyclePaused() {
    // When Android backgrounds the app, mark active transfers so they can
    // smoothly recover or report status if the OS suspends network sockets.
    _notifyThrottled(force: true);
  }

  void onAppLifecycleResumed() {
    _notifyThrottled(force: true);
    _pumpQueue();
  }

  void _pumpQueue() {
    while (_activeCount < maxConcurrentTransfers) {
      final nextIndex =
          _tasks.lastIndexWhere((t) => t.state == TransferState.queued);
      if (nextIndex < 0) break;
      final task = _tasks[nextIndex];
      task.state = TransferState.preparing;
      _activeCount++;
      _runTask(task).whenComplete(() {
        _activeCount = math.max(0, _activeCount - 1);
        _pumpQueue();
      });
    }
  }

  Future<void> _runTask(TransferTask task) async {
    if (task.cancelRequested || task.state == TransferState.cancelled) {
      return;
    }
    task.startedAt = DateTime.now();
    switch (task.type) {
      case TransferType.upload:
        await _executeUpload(task);
        break;
      case TransferType.download:
        await _executeDownload(task);
        break;
      case TransferType.bulkDownload:
        await _executeBulkDownload(task);
        break;
    }
  }

  void _updateSpeedAndEta(
    TransferTask task,
    int newTransferredBytes, {
    required DateTime transferStartTime,
    required int baselineBytes,
  }) {
    task.transferredBytes = newTransferredBytes;
    final elapsedMs =
        DateTime.now().difference(transferStartTime).inMilliseconds;
    final deltaBytes = math.max(0, newTransferredBytes - baselineBytes);
    if (elapsedMs > 250 && deltaBytes > 0) {
      final speed = (deltaBytes * 1000.0) / elapsedMs;
      task.speedBytesPerSec = task.speedBytesPerSec <= 0
          ? speed
          : (task.speedBytesPerSec * 0.35 + speed * 0.65);
      if (task.totalBytes > newTransferredBytes && task.speedBytesPerSec > 1) {
        final remainingBytes = task.totalBytes - newTransferredBytes;
        task.etaSeconds = (remainingBytes / task.speedBytesPerSec).ceil();
      } else {
        task.etaSeconds = 0;
      }
    }
    _notifyThrottled();
  }

  Future<void> _executeUpload(TransferTask task) async {
    final sourcePath = task.localSourcePath;
    if (sourcePath == null) {
      task.state = TransferState.failed;
      task.errorMessage = 'Missing local file path';
      _notifyThrottled(force: true);
      return;
    }

    final file = File(sourcePath);
    if (!await file.exists()) {
      task.state = TransferState.failed;
      task.errorMessage = 'Local file does not exist';
      _notifyThrottled(force: true);
      return;
    }

    task.state = TransferState.preparing;
    _notifyThrottled(force: true);

    final fileSize = await file.length();
    task.totalBytes = fileSize;

    // Route files > chunkThresholdBytes (or resumed sessions) through chunked upload protocol.
    // Small files (<= chunkThresholdBytes) can use the existing single-request endpoint,
    // while large files are always divided into chunks.
    if (fileSize <= chunkThresholdBytes && task.uploadSessionId == null) {
      await _executeSmallFileUpload(task, fileSize);
    } else {
      await _executeChunkedUpload(task, file, fileSize);
    }
  }

  Future<void> _executeSmallFileUpload(
    TransferTask task,
    int fileSize,
  ) async {
    final token = CancelToken();
    task.activeCancelToken = token;
    task.totalChunks = 1;
    task.currentChunk = 0;
    task.state = TransferState.uploading;
    final startTime = DateTime.now();
    _notifyThrottled(force: true);

    try {
      await api.upload(
        task.remotePath,
        task.localSourcePath!,
        fileName: task.fileName,
        cancelToken: token,
        onProgress: (sent, total) {
          if (task.cancelRequested) return;
          if (total > 0) task.totalBytes = total;
          _updateSpeedAndEta(
            task,
            sent,
            transferStartTime: startTime,
            baselineBytes: 0,
          );
        },
      );

      if (task.cancelRequested) {
        task.state = TransferState.cancelled;
        _notifyThrottled(force: true);
        return;
      }

      task.transferredBytes = fileSize;
      task.state = TransferState.completed;
      task.speedBytesPerSec = 0;
      task.etaSeconds = 0;
      task.activeCancelToken = null;
      _notifyThrottled(force: true);

      onNotify?.call('${task.fileName} uploaded');
      await onUploadCompleted?.call();
    } catch (e) {
      task.activeCancelToken = null;
      if (task.cancelRequested ||
          (e is DioException && CancelToken.isCancel(e))) {
        task.state = TransferState.cancelled;
      } else {
        task.state = TransferState.failed;
        task.errorMessage = api.errorMessage(e);
        onNotify?.call(
          'Upload failed (${task.fileName}): ${task.errorMessage}',
          error: true,
        );
      }
      _notifyThrottled(force: true);
    }
  }

  Future<void> _executeChunkedUpload(
    TransferTask task,
    File file,
    int fileSize,
  ) async {
    RandomAccessFile? raf;
    try {
      final totalChunks =
          fileSize == 0 ? 1 : (fileSize / chunkSize).ceil();
      task.totalChunks = totalChunks;

      final initToken = CancelToken();
      task.activeCancelToken = initToken;

      final session = await api.initChunkedUpload(
        fileName: task.fileName,
        filePath: task.remotePath,
        totalSize: fileSize,
        chunkSize: chunkSize,
        totalChunks: totalChunks,
        uploadId: task.uploadSessionId,
        resume: true,
        cancelToken: initToken,
      );

      if (task.cancelRequested) {
        await api.cancelChunkedUpload(session.uploadId);
        task.state = TransferState.cancelled;
        _notifyThrottled(force: true);
        return;
      }

      task.uploadSessionId = session.uploadId;
      final effectiveChunkSize = session.chunkSize;
      final effectiveTotalChunks = session.totalChunks;
      task.totalChunks = effectiveTotalChunks;

      final receivedSet = session.receivedChunks.toSet();
      int completedChunkBytes = 0;
      for (final idx in receivedSet) {
        completedChunkBytes += _expectedChunkSize(
          fileSize,
          effectiveChunkSize,
          effectiveTotalChunks,
          idx,
        );
      }

      task.transferredBytes = completedChunkBytes;
      task.state = TransferState.uploading;
      final transferStartTime = DateTime.now();
      final baselineBytes = completedChunkBytes;
      _notifyThrottled(force: true);

      final openedRaf = await file.open(mode: FileMode.read);
      raf = openedRaf;

      for (int chunkIndex = 0;
          chunkIndex < effectiveTotalChunks;
          chunkIndex++) {
        if (task.cancelRequested) {
          await openedRaf.close();
          raf = null;
          await api.cancelChunkedUpload(session.uploadId);
          task.state = TransferState.cancelled;
          _notifyThrottled(force: true);
          return;
        }

        if (receivedSet.contains(chunkIndex)) {
          continue;
        }

        task.currentChunk = chunkIndex;
        final offset = chunkIndex * effectiveChunkSize;
        final expectedLen = _expectedChunkSize(
          fileSize,
          effectiveChunkSize,
          effectiveTotalChunks,
          chunkIndex,
        );

        await openedRaf.setPosition(offset);
        final chunkBytes = await openedRaf.read(expectedLen);
        if (chunkBytes.length != expectedLen) {
          throw Exception(
            'Local file read size mismatch on chunk $chunkIndex '
            '(expected $expectedLen, got ${chunkBytes.length})',
          );
        }

        bool chunkUploaded = false;
        Object? lastChunkError;

        for (int attempt = 0; attempt <= maxChunkRetries; attempt++) {
          if (task.cancelRequested) break;

          if (attempt > 0) {
            final delayMs = 700 * (1 << (attempt - 1));
            await Future<void>.delayed(Duration(milliseconds: delayMs));
            if (task.cancelRequested) break;

            // Check with backend if chunk was actually received before network drop
            try {
              final status = await api.getUploadStatus(session.uploadId);
              if (status.receivedChunks.contains(chunkIndex)) {
                chunkUploaded = true;
                break;
              }
            } catch (_) {}
          }

          final chunkToken = CancelToken();
          task.activeCancelToken = chunkToken;

          try {
            await api.uploadChunk(
              uploadId: session.uploadId,
              chunkIndex: chunkIndex,
              chunkBytes: chunkBytes,
              cancelToken: chunkToken,
              onSendProgress: (sent, total) {
                if (task.cancelRequested) return;
                final boundedSent = math.min(sent, expectedLen);
                _updateSpeedAndEta(
                  task,
                  completedChunkBytes + boundedSent,
                  transferStartTime: transferStartTime,
                  baselineBytes: baselineBytes,
                );
              },
            );
            chunkUploaded = true;
            break;
          } catch (e) {
            if (task.cancelRequested ||
                (e is DioException && CancelToken.isCancel(e))) {
              break;
            }
            lastChunkError = e;
          }
        }

        if (task.cancelRequested) {
          await openedRaf.close();
          raf = null;
          await api.cancelChunkedUpload(session.uploadId);
          task.state = TransferState.cancelled;
          _notifyThrottled(force: true);
          return;
        }

        if (!chunkUploaded) {
          throw lastChunkError ??
              Exception('Failed to upload chunk $chunkIndex after retries');
        }

        receivedSet.add(chunkIndex);
        completedChunkBytes += expectedLen;
        _updateSpeedAndEta(
          task,
          completedChunkBytes,
          transferStartTime: transferStartTime,
          baselineBytes: baselineBytes,
        );
      }

      await openedRaf.close();
      raf = null;

      if (task.cancelRequested) {
        await api.cancelChunkedUpload(session.uploadId);
        task.state = TransferState.cancelled;
        _notifyThrottled(force: true);
        return;
      }

      task.state = TransferState.finalizing;
      final finalizeToken = CancelToken();
      task.activeCancelToken = finalizeToken;
      _notifyThrottled(force: true);

      await api.completeChunkedUpload(
        session.uploadId,
        cancelToken: finalizeToken,
      );

      if (task.cancelRequested) {
        task.state = TransferState.cancelled;
        _notifyThrottled(force: true);
        return;
      }

      task.transferredBytes = fileSize;
      task.state = TransferState.completed;
      task.speedBytesPerSec = 0;
      task.etaSeconds = 0;
      task.activeCancelToken = null;
      _notifyThrottled(force: true);

      onNotify?.call('${task.fileName} uploaded');
      await onUploadCompleted?.call();
    } catch (e) {
      try {
        await raf?.close();
      } catch (_) {}
      task.activeCancelToken = null;

      if (task.cancelRequested ||
          (e is DioException && CancelToken.isCancel(e))) {
        if (task.uploadSessionId != null) {
          try {
            await api.cancelChunkedUpload(task.uploadSessionId!);
          } catch (_) {}
        }
        task.state = TransferState.cancelled;
      } else {
        task.state = TransferState.failed;
        task.errorMessage = api.errorMessage(e);
        onNotify?.call(
          'Upload failed (${task.fileName}): ${task.errorMessage}',
          error: true,
        );
      }
      _notifyThrottled(force: true);
    }
  }

  int _expectedChunkSize(
    int totalSize,
    int chunkSize,
    int totalChunks,
    int chunkIndex,
  ) {
    if (totalSize == 0) return 0;
    if (chunkIndex < totalChunks - 1) return chunkSize;
    return totalSize - (chunkIndex * chunkSize);
  }

  Future<void> _executeDownload(TransferTask task) async {
    final targetPath = task.localTargetPath;
    final fileId = task.remoteFileId;
    if (targetPath == null || fileId == null) {
      task.state = TransferState.failed;
      task.errorMessage = 'Invalid download configuration';
      _notifyThrottled(force: true);
      return;
    }

    final partPath = '$targetPath.overcast.part';
    final token = CancelToken();
    task.activeCancelToken = token;
    task.state = TransferState.downloading;
    final startTime = DateTime.now();
    _notifyThrottled(force: true);

    try {
      await api.downloadToPath(
        fileId,
        partPath,
        cancelToken: token,
        onProgress: (done, total) {
          if (task.cancelRequested) return;
          if (total > 0) task.totalBytes = total;
          _updateSpeedAndEta(
            task,
            done,
            transferStartTime: startTime,
            baselineBytes: 0,
          );
        },
      );

      if (task.cancelRequested) {
        await _cleanupPartialDownload(task);
        task.state = TransferState.cancelled;
        _notifyThrottled(force: true);
        return;
      }

      task.state = TransferState.finalizing;
      _notifyThrottled(force: true);

      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.rename(targetPath);
      }

      task.transferredBytes = task.totalBytes > 0
          ? task.totalBytes
          : await File(targetPath).length();
      task.totalBytes = task.transferredBytes;
      task.state = TransferState.completed;
      task.speedBytesPerSec = 0;
      task.etaSeconds = 0;
      task.activeCancelToken = null;
      _notifyThrottled(force: true);

      onNotify?.call('Downloaded ${task.fileName}');
    } catch (e) {
      task.activeCancelToken = null;
      await _cleanupPartialDownload(task);
      if (task.cancelRequested ||
          (e is DioException && CancelToken.isCancel(e))) {
        task.state = TransferState.cancelled;
      } else {
        task.state = TransferState.failed;
        task.errorMessage = api.errorMessage(e);
        onNotify?.call(
          'Download failed (${task.fileName}): ${task.errorMessage}',
          error: true,
        );
      }
      _notifyThrottled(force: true);
    }
  }

  Future<void> _executeBulkDownload(TransferTask task) async {
    final targetPath = task.localTargetPath;
    if (targetPath == null) {
      task.state = TransferState.failed;
      task.errorMessage = 'Invalid download path';
      _notifyThrottled(force: true);
      return;
    }

    final partPath = '$targetPath.overcast.part';
    final token = CancelToken();
    task.activeCancelToken = token;
    task.state = TransferState.preparing;
    final startTime = DateTime.now();
    _notifyThrottled(force: true);

    try {
      await api.bulkDownloadToPath(
        fileIds: task.bulkFileIds,
        folderPaths: task.bulkFolderPaths,
        basePath: task.remotePath,
        archiveName: task.fileName,
        outputPath: partPath,
        cancelToken: token,
        onProgress: (received, total) {
          if (task.cancelRequested) return;
          if (task.state != TransferState.downloading) {
            task.state = TransferState.downloading;
          }
          if (total > 0) task.totalBytes = total;
          _updateSpeedAndEta(
            task,
            received,
            transferStartTime: startTime,
            baselineBytes: 0,
          );
        },
      );

      if (task.cancelRequested) {
        await _cleanupPartialDownload(task);
        task.state = TransferState.cancelled;
        _notifyThrottled(force: true);
        return;
      }

      task.state = TransferState.finalizing;
      _notifyThrottled(force: true);

      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.rename(targetPath);
      }

      final finalLen = await File(targetPath).length();
      task.transferredBytes = finalLen;
      task.totalBytes = finalLen;
      task.state = TransferState.completed;
      task.speedBytesPerSec = 0;
      task.etaSeconds = 0;
      task.activeCancelToken = null;
      _notifyThrottled(force: true);

      onNotify?.call('Bulk ZIP downloaded: ${task.fileName}');
    } catch (e) {
      task.activeCancelToken = null;
      await _cleanupPartialDownload(task);
      if (task.cancelRequested ||
          (e is DioException && CancelToken.isCancel(e))) {
        task.state = TransferState.cancelled;
      } else {
        task.state = TransferState.failed;
        task.errorMessage = api.errorMessage(e);
        onNotify?.call(
          'Bulk download failed: ${task.errorMessage}',
          error: true,
        );
      }
      _notifyThrottled(force: true);
    }
  }

  Future<void> _cleanupPartialDownload(TransferTask task) async {
    final targetPath = task.localTargetPath;
    if (targetPath == null) return;
    final partFile = File('$targetPath.overcast.part');
    try {
      if (await partFile.exists()) {
        await partFile.delete();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _trailingNotifyTimer?.cancel();
    for (final t in _tasks) {
      t.activeCancelToken?.cancel('Disposed');
    }
    super.dispose();
  }
}
