import 'package:flutter_test/flutter_test.dart';
import 'package:genesmanproxy/genesmanproxy.dart';

void main() {
  group('DownloadMeta', () {
    test('should track byte ranges', () {
      final meta = DownloadMeta(
        id: 'test',
        totalSize: 1000,
        localPath: '/tmp/test.video',
        metaPath: '/tmp/test.meta',
      );

      meta.addRange(0, 100);
      expect(meta.hasRange(0, 100), isTrue);
      expect(meta.hasRange(50, 75), isTrue);
      expect(meta.hasRange(101, 200), isFalse);
    });

    test('should merge overlapping ranges', () {
      final meta = DownloadMeta(
        id: 'test',
        totalSize: 1000,
        localPath: '/tmp/test.video',
        metaPath: '/tmp/test.meta',
      );

      meta.addRange(0, 100);
      meta.addRange(101, 200);
      meta.addRange(150, 250);

      expect(meta.hasRange(0, 250), isTrue);
    });

    test('should calculate progress correctly', () {
      final meta = DownloadMeta(
        id: 'test',
        totalSize: 1000,
        localPath: '/tmp/test.video',
        metaPath: '/tmp/test.meta',
      );

      meta.addRange(0, 499);
      expect(meta.progress, closeTo(50.0, 0.1));
    });

    test('should detect complete download', () {
      final meta = DownloadMeta(
        id: 'test',
        totalSize: 1000,
        localPath: '/tmp/test.video',
        metaPath: '/tmp/test.meta',
      );

      expect(meta.isComplete, isFalse);
      meta.addRange(0, 999);
      expect(meta.isComplete, isTrue);
    });
  });

  group('MimeTypeDetector', () {
    test('should detect MP4 video', () {
      // Valid MP4 signature: 4 bytes size + 'ftyp' + mp4 brand
      final bytes = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x31, 0x00, 0x00, 0x00, 0x00];
      final mimeType = MimeTypeDetector.detectFromBytes(bytes);
      expect(mimeType, equals('video/mp4'));
    });

    test('should detect JPEG image', () {
      final bytes = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final mimeType = MimeTypeDetector.detectFromBytes(bytes);
      expect(mimeType, equals('image/jpeg'));
    });

    test('should detect PNG image', () {
      final bytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final mimeType = MimeTypeDetector.detectFromBytes(bytes);
      expect(mimeType, equals('image/png'));
    });

    test('should detect PDF', () {
      final bytes = [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final mimeType = MimeTypeDetector.detectFromBytes(bytes);
      expect(mimeType, equals('application/pdf'));
    });

    test('should detect ZIP', () {
      final bytes = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final mimeType = MimeTypeDetector.detectFromBytes(bytes);
      expect(mimeType, equals('application/zip'));
    });

    test('should return null for unknown format', () {
      final bytes = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F];
      final mimeType = MimeTypeDetector.detectFromBytes(bytes);
      expect(mimeType, isNull);
    });
  });

  group('FileStat', () {
    test('should create file stat', () {
      final stat = FileStat(
        fileName: 'video.mp4',
        totalSize: 1024000,
        mimeType: 'video/mp4',
        extension: 'mp4',
      );

      expect(stat.fileName, equals('video.mp4'));
      expect(stat.totalSize, equals(1024000));
      expect(stat.mimeType, equals('video/mp4'));
      expect(stat.extension, equals('mp4'));
    });
  });

  group('ProxyConfig', () {
    test('should create HTTP proxy config', () {
      final config = ProxyConfig(
        host: 'proxy.example.com',
        port: 8080,
        type: ProxyType.http,
      );

      expect(config.host, equals('proxy.example.com'));
      expect(config.port, equals(8080));
      expect(config.type, equals(ProxyType.http));
    });

    test('should create SOCKS5 proxy config', () {
      final config = ProxyConfig(
        host: 'socks.example.com',
        port: 1080,
        type: ProxyType.socks5,
        username: 'user',
        password: 'pass',
      );

      expect(config.type, equals(ProxyType.socks5));
      expect(config.username, equals('user'));
      expect(config.password, equals('pass'));
    });
  });
}
