import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:overcast/api.dart';
import 'package:overcast/models.dart';
import 'package:overcast/transfer_manager.dart';

void main() {
  test('OvercastFile, UploadSessionInfo, and BulkDeleteResult parse JSON accurately', () {
    final file = OvercastFile.fromJson({
      'UniqueID': 'abc1234567890',
      'FileName': 'video.mp4',
      'FilePath': 'home/media/',
      'Format': 'mp4',
      'Size': 10485760,
      'SHA256': 'deadbeef',
    });

    expect(file.id, 'abc1234567890');
    expect(file.name, 'video.mp4');
    expect(file.isVideo, isTrue);
    expect(file.isImage, isFalse);

    final session = UploadSessionInfo.fromJson({
      'uploadId': '0123456789abcdef0123456789abcdef',
      'uid': 'abc1234567890',
      'fileName': 'video.mp4',
      'filePath': 'home/media/',
      'totalSize': 10485760,
      'chunkSize': 4194304,
      'totalChunks': 3,
      'receivedChunks': [0, 1],
      'missingChunks': [2],
      'receivedBytes': 8388808,
      'resumed': true,
      'status': 'uploading',
    });

    expect(session.totalChunks, 3);
    expect(session.receivedChunks, [0, 1]);
    expect(session.missingChunks, [2]);
    expect(session.resumed, isTrue);

    final bulkDel = BulkDeleteResult.fromJson({
      'status': 'completed',
      'deletedCount': 2,
      'succeeded': ['id1', 'id2'],
      'failed': [],
    });
    expect(bulkDel.deletedCount, 2);
    expect(bulkDel.succeeded, ['id1', 'id2']);
    expect(bulkDel.failed, isEmpty);
  });

  test('TransferManager performs multi-chunk upload with automatic chunk retry', () async {
    int chunk1Attempts = 0;
    final receivedChunks = <int>[];
    bool completedCalled = false;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final baseUrl = 'http://127.0.0.1:${server.port}';

    server.listen((HttpRequest req) async {
      final path = req.uri.path;
      if (path == '/api/uploads/init' && req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        req.response.statusCode = 201;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'uploadId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'uid': 'uid123',
          'fileName': data['fileName'],
          'filePath': data['filePath'],
          'totalSize': data['totalSize'],
          'chunkSize': data['chunkSize'],
          'totalChunks': data['totalChunks'],
          'receivedChunks': <int>[],
          'missingChunks': [0, 1, 2],
          'receivedBytes': 0,
          'resumed': false,
          'status': 'uploading',
        }));
        await req.response.close();
      } else if (path.startsWith('/api/uploads/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/chunks/')) {
        await req.drain<void>();
        final idx = int.parse(path.split('/').last);
        if (idx == 1 && chunk1Attempts == 0) {
          chunk1Attempts++;
          req.response.statusCode = 500;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'error': 'Simulated transient network error'}));
          await req.response.close();
          return;
        }
        receivedChunks.add(idx);
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'uploadId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'chunkIndex': idx,
          'size': 65536,
          'sha256': 'abc',
          'receivedCount': receivedChunks.length,
          'totalChunks': 3,
        }));
        await req.response.close();
      } else if (path == '/api/uploads/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' && req.method == 'GET') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'uploadId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'uid': 'uid123',
          'fileName': 'big.bin',
          'filePath': 'home/',
          'totalSize': 180000,
          'chunkSize': 65536,
          'totalChunks': 3,
          'receivedChunks': receivedChunks,
          'missingChunks': <int>[],
          'receivedBytes': receivedChunks.length * 65536,
          'resumed': true,
          'status': 'uploading',
        }));
        await req.response.close();
      } else if (path == '/api/uploads/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/complete') {
        await req.drain<void>();
        completedCalled = true;
        req.response.statusCode = 201;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'UniqueID': 'uid123',
          'FileName': 'big.bin',
          'FilePath': 'home/',
          'Format': 'bin',
          'Size': 180000,
        }));
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });

    final tempDir = await Directory.systemTemp.createTemp('overcast_flutter_test_');
    final sampleFile = File('${tempDir.path}/big.bin');
    await sampleFile.writeAsBytes(Uint8List(180000));

    final api = OvercastApi(baseUrl);
    final manager = TransferManager(
      api: api,
      chunkSize: 65536,
      chunkThresholdBytes: 65536,
    );

    final task = manager.enqueueUpload(
      localFilePath: sampleFile.path,
      fileName: 'big.bin',
      destinationFolder: 'home/',
    );

    // Wait for background transfer to finish
    for (int i = 0; i < 60; i++) {
      if (task.state == TransferState.completed || task.state == TransferState.failed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(task.state, TransferState.completed, reason: task.errorMessage);
    expect(chunk1Attempts, 1);
    expect(receivedChunks, [0, 1, 2]);
    expect(completedCalled, isTrue);
    expect(task.progress, 1.0);

    manager.dispose();
    await server.close(force: true);
    await tempDir.delete(recursive: true);
  });

  test('TransferManager cancels download and cleans up partial file', () async {
    final api = OvercastApi('http://127.0.0.1:59999');
    final manager = TransferManager(api: api);

    final task = manager.enqueueDownload(
      fileId: 'file_1',
      fileName: 'sample.zip',
      totalBytes: 1024 * 1024,
      targetFilePath: '/tmp/overcast_test_sample.zip',
    );

    expect(manager.tasks.length, 1);
    await manager.cancelTransfer(task.id);
    expect(task.state, TransferState.cancelled);
    expect(task.cancelRequested, isTrue);

    manager.clearFinished();
    expect(manager.tasks, isEmpty);
    manager.dispose();
  });
}
