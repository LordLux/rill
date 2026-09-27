import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_downloader.dart';
import 'package:rill/data/update/update_http.dart';
import 'package:rill/domain/update/update_manifest.dart';
import 'package:rill/domain/update/app_version.dart';

class FakeHttp implements UpdateHttp {
  final List<int> bytesToServe;
  final bool shouldThrow;

  FakeHttp({required this.bytesToServe, this.shouldThrow = false});

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) async {
    throw UnimplementedError();
  }

  @override
  Future<Stream<List<int>>> openStream(Uri url) async {
    if (shouldThrow) throw UpdateNetworkException('error');
    // Two-byte chunks, so the size cap is hit mid-stream rather than at the end.
    return Stream.fromIterable([for (var i = 0; i < bytesToServe.length; i += 2) bytesToServe.sublist(i, (i + 2).clamp(0, bytesToServe.length))]);
  }
}

void main() {
  late Directory tempDir;
  
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('updater_test_');
  });
  
  tearDown(() async {
    if (tempDir.existsSync()) {
      try { tempDir.deleteSync(recursive: true); } catch (_) {}
    }
  });

  final dummyManifest = UpdateManifest(
    schema: 1,
    version: const AppVersion(major: 1, minor: 0, patch: 0),
    tag: 'v1.0.0',
    notes: [],
    windowsX64: UpdateAsset(
      name: 'r.zip',
      url: Uri.parse('http://127.0.0.1/r.zip'),
      sha256: '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
      size: 4,
    ),
  );

  test('Happy path download', () async {
    final http = FakeHttp(bytesToServe: utf8.encode('test'));
    final downloader = UpdateDownloader(http: http, root: tempDir);
    
    int reportedReceived = 0;
    final file = await downloader.download(dummyManifest, onProgress: (r, t) {
      reportedReceived = r;
    });
    
    expect(file.existsSync(), isTrue);
    expect(file.path.endsWith('r.zip'), isTrue);
    expect(reportedReceived, 4);
    
    final partial = File('${file.path}.partial');
    expect(partial.existsSync(), isFalse);
  });

  test('Hash mismatch throws and deletes partial', () async {
    final http = FakeHttp(bytesToServe: utf8.encode('bad_'));
    final downloader = UpdateDownloader(http: http, root: tempDir);
    
    await expectLater(() => downloader.download(dummyManifest), throwsA(isA<UpdateIntegrityException>()));
    
    final finalFile = File('${tempDir.path}\\1.0.0\\r.zip');
    final partialFile = File('${finalFile.path}.partial');
    expect(finalFile.existsSync(), isFalse);
    expect(partialFile.existsSync(), isFalse);
  });

  test('Server sends more bytes', () async {
    final http = FakeHttp(bytesToServe: utf8.encode('test_extra'));
    final downloader = UpdateDownloader(http: http, root: tempDir);
    
    await expectLater(() => downloader.download(dummyManifest), throwsA(isA<UpdateIntegrityException>()));
    
    final finalFile = File('${tempDir.path}\\1.0.0\\r.zip');
    expect(finalFile.existsSync(), isFalse);
    expect(File('${finalFile.path}.partial').existsSync(), isFalse);
  });

  test('Server sends fewer bytes', () async {
    final http = FakeHttp(bytesToServe: utf8.encode('tes'));
    final downloader = UpdateDownloader(http: http, root: tempDir);
    
    await expectLater(() => downloader.download(dummyManifest), throwsA(isA<UpdateIntegrityException>()));
  });

  test('Existing valid file => no http call', () async {
    final targetDir = Directory('${tempDir.path}\\1.0.0')..createSync(recursive: true);
    final finalFile = File('${targetDir.path}\\r.zip');
    finalFile.writeAsBytesSync(utf8.encode('test'));
    
    final http = FakeHttp(bytesToServe: utf8.encode('new_data'), shouldThrow: true);
    final downloader = UpdateDownloader(http: http, root: tempDir);
    
    final res = await downloader.download(dummyManifest);
    expect(res.path, finalFile.path);
    expect(res.readAsStringSync(), 'test');
  });

  test('Existing corrupt file => re-downloaded', () async {
    final targetDir = Directory('${tempDir.path}\\1.0.0')..createSync(recursive: true);
    final finalFile = File('${targetDir.path}\\r.zip');
    finalFile.writeAsBytesSync(utf8.encode('corrupt'));
    
    final http = FakeHttp(bytesToServe: utf8.encode('test'));
    final downloader = UpdateDownloader(http: http, root: tempDir);
    
    final res = await downloader.download(dummyManifest);
    expect(res.path, finalFile.path);
    expect(res.readAsStringSync(), 'test');
  });

  test('deleteStale keeps only given version', () async {
    final d1 = Directory('${tempDir.path}\\0.9.0')..createSync(recursive: true);
    final d2 = Directory('${tempDir.path}\\1.0.0')..createSync(recursive: true);
    final d3 = Directory('${tempDir.path}\\1.1.0')..createSync(recursive: true);
    
    final downloader = UpdateDownloader(http: FakeHttp(bytesToServe: []), root: tempDir);
    await downloader.deleteStale(keepVersion: '1.0.0');
    
    expect(d1.existsSync(), isFalse);
    expect(d2.existsSync(), isTrue);
    expect(d3.existsSync(), isFalse);
  });

  test('Invalid asset name rejected', () async {
    final badManifest = UpdateManifest(
      schema: 1,
      version: const AppVersion(major: 1, minor: 0, patch: 0),
      tag: 'v1.0.0',
      notes: [],
      windowsX64: UpdateAsset(
        name: '..\\x.exe',
        url: Uri.parse('http://127.0.0.1/r.zip'),
        sha256: '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
        size: 4,
      ),
    );
    
    final downloader = UpdateDownloader(http: FakeHttp(bytesToServe: []), root: tempDir);
    await expectLater(() => downloader.download(badManifest), throwsA(isA<UpdateIntegrityException>()));
  });
}
