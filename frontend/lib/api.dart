import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'models.dart';

class OvercastApi {
  final Dio dio;

  OvercastApi(String baseUrl)
      : dio = Dio(BaseOptions(
          baseUrl: baseUrl.trim().replaceFirst(RegExp(r'/*$'), ''),
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(minutes: 10),
          headers: const {'Accept': 'application/json'},
        ));

  dynamic _json(Response response) => response.data is String
      ? jsonDecode(response.data as String)
      : response.data;

  String errorMessage(Object error) {
    if (error is DioException) {
      if (CancelToken.isCancel(error)) {
        return 'Transfer cancelled';
      }
      final data = error.response?.data;
      if (data is Map && data['error'] != null) return '${data['error']}';
      if (data is String && data.isNotEmpty) {
        try {
          final parsed = jsonDecode(data);
          if (parsed is Map && parsed['error'] != null) {
            return '${parsed['error']}';
          }
        } catch (_) {}
        return data;
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.connectionError) {
        return 'Overcast is unreachable on this network.';
      }
      return error.message ?? 'Network error';
    }
    return error.toString();
  }

  Future<bool> isHealthy() async {
    final response = await dio.get('/api/health');
    final data = Map<String, dynamic>.from(_json(response) as Map);
    return data['status'] == 'ok' &&
        data['database'] == true &&
        data['storage'] == true;
  }

  Future<StorageInfo> storage() async {
    final response = await dio.get('/api/storage');
    return StorageInfo.fromJson(
        Map<String, dynamic>.from(_json(response) as Map));
  }

  Future<List<OvercastFile>> files([String? path]) async {
    final response = await dio.get(
      '/api/files',
      queryParameters: path == null ? null : {'path': path},
    );
    final data = _json(response) as List;
    return data
        .map((e) => OvercastFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<OvercastFile> file(String id) async {
    final response = await dio.get('/api/files/$id');
    return OvercastFile.fromJson(
        Map<String, dynamic>.from(_json(response) as Map));
  }

  Future<OvercastFile> upload(
    String path,
    String filePath, {
    String? fileName,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final name = (fileName != null && fileName.isNotEmpty)
        ? fileName
        : filePath.split(RegExp(r'[/\\]')).last;
    final form = FormData.fromMap({
      'path': path,
      'encryption': 'none',
      'file': await MultipartFile.fromFile(filePath, filename: name),
    });
    final response = await dio.post(
      '/api/files/upload',
      data: form,
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    return OvercastFile.fromJson(
        Map<String, dynamic>.from(_json(response) as Map));
  }

  Future<OvercastFile> createText(
      String name, String path, String content) async {
    try {
      final response = await dio.post(
        '/api/files/text',
        data: {
          'fileName': name,
          'filePath': path,
          'content': content,
        },
      );
      return OvercastFile.fromJson(
          Map<String, dynamic>.from(_json(response) as Map));
    } catch (_) {
      return uploadBytes(
        path,
        name,
        Uint8List.fromList(utf8.encode(content)),
      );
    }
  }

  Future<OvercastFile> uploadBytes(
    String path,
    String name,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final form = FormData.fromMap({
      'path': path,
      'encryption': 'none',
      'file': MultipartFile.fromBytes(bytes, filename: name),
    });
    final response = await dio.post(
      '/api/files/upload',
      data: form,
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    return OvercastFile.fromJson(
        Map<String, dynamic>.from(_json(response) as Map));
  }

  // --- Chunked Upload API Methods ---

  Future<UploadSessionInfo> initChunkedUpload({
    required String fileName,
    required String filePath,
    required int totalSize,
    required int chunkSize,
    required int totalChunks,
    String? sha256,
    String? uploadId,
    bool resume = true,
    CancelToken? cancelToken,
  }) async {
    final response = await dio.post(
      '/api/uploads/init',
      data: {
        'fileName': fileName,
        'filePath': filePath,
        'totalSize': totalSize,
        'chunkSize': chunkSize,
        'totalChunks': totalChunks,
        if (sha256 != null) 'sha256': sha256,
        if (uploadId != null) 'uploadId': uploadId,
        'resume': resume,
        'encryption': 'none',
      },
      cancelToken: cancelToken,
    );
    return UploadSessionInfo.fromJson(
      Map<String, dynamic>.from(_json(response) as Map),
    );
  }

  Future<ChunkUploadResult> uploadChunk({
    required String uploadId,
    required int chunkIndex,
    required Uint8List chunkBytes,
    String? chunkSha256,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final form = FormData.fromMap({
      'chunk': MultipartFile.fromBytes(
        chunkBytes,
        filename: 'chunk_$chunkIndex.part',
      ),
      if (chunkSha256 != null) 'sha256': chunkSha256,
    });
    final response = await dio.put(
      '/api/uploads/$uploadId/chunks/$chunkIndex',
      data: form,
      options: Options(
        headers: {
          if (chunkSha256 != null) 'X-Chunk-SHA256': chunkSha256,
        },
      ),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    return ChunkUploadResult.fromJson(
      Map<String, dynamic>.from(_json(response) as Map),
    );
  }

  Future<UploadSessionInfo> getUploadStatus(
    String uploadId, {
    CancelToken? cancelToken,
  }) async {
    final response = await dio.get(
      '/api/uploads/$uploadId',
      cancelToken: cancelToken,
    );
    return UploadSessionInfo.fromJson(
      Map<String, dynamic>.from(_json(response) as Map),
    );
  }

  Future<OvercastFile> completeChunkedUpload(
    String uploadId, {
    String? sha256,
    CancelToken? cancelToken,
  }) async {
    final response = await dio.post(
      '/api/uploads/$uploadId/complete',
      data: {
        if (sha256 != null) 'sha256': sha256,
      },
      cancelToken: cancelToken,
    );
    return OvercastFile.fromJson(
      Map<String, dynamic>.from(_json(response) as Map),
    );
  }

  Future<void> cancelChunkedUpload(String uploadId) async {
    await dio.delete('/api/uploads/$uploadId');
  }

  // --- Download & Bulk Operations API Methods ---

  Future<String> downloadToPath(
    String id,
    String outputPath, {
    void Function(int, int)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await dio.download(
      '/api/files/$id/download',
      outputPath,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return outputPath;
  }

  Future<String> bulkDownloadToPath({
    List<String> fileIds = const [],
    List<String> folderPaths = const [],
    required String basePath,
    required String archiveName,
    required String outputPath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final response = await dio.post<ResponseBody>(
      '/api/files/bulk-download',
      data: {
        'fileIds': fileIds,
        'folderPaths': folderPaths,
        'basePath': basePath,
        'archiveName': archiveName,
      },
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(hours: 2),
      ),
      cancelToken: cancelToken,
    );

    final body = response.data;
    if (body == null) {
      throw Exception('Empty response stream from server');
    }

    final totalHeader = response.headers.value(Headers.contentLengthHeader);
    final totalBytes = int.tryParse(totalHeader ?? '') ?? -1;

    final outFile = File(outputPath);
    await outFile.parent.create(recursive: true);
    final sink = outFile.openWrite();

    int receivedBytes = 0;
    try {
      await for (final chunk in body.stream) {
        if (cancelToken != null && cancelToken.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: response.requestOptions,
            reason: 'Cancelled by user',
          );
        }
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(receivedBytes, totalBytes);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    return outputPath;
  }

  Future<BulkDeleteResult> bulkDelete({
    List<String> fileIds = const [],
    List<String> folderPaths = const [],
    bool permanent = false,
  }) async {
    final response = await dio.post(
      '/api/files/bulk-delete',
      data: {
        'fileIds': fileIds,
        'folderPaths': folderPaths,
        'permanent': permanent,
      },
    );
    return BulkDeleteResult.fromJson(
      Map<String, dynamic>.from(_json(response) as Map),
    );
  }

  String previewUrl(String id) =>
      '${dio.options.baseUrl}/api/files/$id/preview';
  String streamUrl(String id) => '${dio.options.baseUrl}/api/files/$id/stream';
  String downloadUrl(String id) =>
      '${dio.options.baseUrl}/api/files/$id/download';

  Future<String> readText(String id) async {
    final response = await dio.get('/api/files/$id/text');
    final data = Map<String, dynamic>.from(_json(response) as Map);
    return '${data['content'] ?? ''}';
  }

  Future<OvercastFile> saveText(String id, String content) async {
    final response =
        await dio.put('/api/files/$id/text', data: {'content': content});
    return OvercastFile.fromJson(
        Map<String, dynamic>.from(_json(response) as Map));
  }

  Future<OvercastFile> moveRename(
      String id, String newPath, String newName) async {
    final response = await dio.put('/api/files/$id/path', data: {
      'newPath': newPath,
      'newName': newName,
    });
    return OvercastFile.fromJson(
        Map<String, dynamic>.from(_json(response) as Map));
  }

  Future<void> trash(String id) async => dio.delete('/api/files/$id');

  Future<List<TrashEntry>> trashList() async {
    final response = await dio.get('/api/trash');
    final data = _json(response) as List;
    return data
        .map((e) => TrashEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> restore(String id) async => dio.post('/api/trash/$id/restore');

  Future<void> permanentlyDelete(String id) async =>
      dio.delete('/api/trash/$id');

  Future<Uint8List> fetchBytes(String id) async {
    final response = await dio.get<List<int>>(
      '/api/files/$id/preview',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? <int>[]);
  }
}
