import 'dart:async';
import 'dart:io';

/// File statistics for preview
class FileStat {
  final String? fileName;
  final int? totalSize;
  final String? mimeType;
  final String? extension;

  FileStat({
    this.fileName,
    this.totalSize,
    this.mimeType,
    this.extension,
  });

  @override
  String toString() =>
      'FileStat(fileName: $fileName, size: $totalSize, mime: $mimeType)';
}

/// Proxy configuration
class ProxyConfig {
  final String? host;
  final int? port;
  final ProxyType type;
  final String? username;
  final String? password;

  ProxyConfig({
    this.host,
    this.port,
    this.type = ProxyType.http,
    this.username,
    this.password,
  });
}

enum ProxyType { http, socks5 }

/// Abstract data source for fetching remote content
abstract class DataSource {
  /// Get file statistics (emitted as soon as headers are received)
  Stream<FileStat> get fileStats;

  /// Fetch data for a specific byte range
  Future<HttpClientResponse> fetchRange(int start, int end);

  /// Get total content length via HEAD request
  Future<int> getContentLength();

  /// Cancel any ongoing operations
  Future<void> cancel();

  /// Dispose resources
  Future<void> dispose();
}

/// Standard HTTP data source
class HttpDataSource implements DataSource {
  final String url;
  final String? userAgent;
  final ProxyConfig? proxyConfig;
  final Map<String, String>? customHeaders;

  final StreamController<FileStat> _fileStatsController =
      StreamController<FileStat>.broadcast();
  
  HttpClient? _client;
  bool _cancelled = false;
  FileStat? _cachedStat;

  HttpDataSource({
    required this.url,
    this.userAgent,
    this.proxyConfig,
    this.customHeaders,
  }) {
    _initClient();
  }

  void _initClient() {
    _client = HttpClient();
    
    // Configure proxy if provided
    if (proxyConfig != null && proxyConfig!.host != null) {
      final proxyUrl = proxyConfig!.type == ProxyType.http
          ? 'PROXY ${proxyConfig!.host}:${proxyConfig!.port ?? 80}'
          : 'SOCKS5 ${proxyConfig!.host}:${proxyConfig!.port ?? 1080}';
      
      _client!.findProxy = (uri) => proxyUrl;
      
      // Set authentication if provided
      if (proxyConfig!.username != null && proxyConfig!.password != null) {
        _client!.addProxyCredentials(
          proxyConfig!.host!,
          proxyConfig!.port ?? (proxyConfig!.type == ProxyType.http ? 80 : 1080),
          '',
          HttpClientBasicCredentials(
            proxyConfig!.username!,
            proxyConfig!.password!,
          ),
        );
      }
    }
  }

  @override
  Stream<FileStat> get fileStats => _fileStatsController.stream;

  @override
  Future<int> getContentLength() async {
    if (_cancelled) throw StateError('Operation cancelled');
    
    if (_cachedStat?.totalSize != null) {
      return _cachedStat!.totalSize!;
    }

    final request = await _client!.headUrl(Uri.parse(url));
    _addHeaders(request);
    
    final response = await request.close();
    final contentLength = response.contentLength;
    
    // Extract file info from headers
    final contentType = response.headers.value('content-type');
    final contentDisposition = response.headers.value('content-disposition');
    final fileName = _extractFileName(contentDisposition) ?? _extractFileNameFromUrl();
    
    _cachedStat = FileStat(
      fileName: fileName,
      totalSize: contentLength > 0 ? contentLength : null,
      mimeType: contentType,
      extension: fileName?.split('.').last,
    );
    
    _fileStatsController.add(_cachedStat!);
    
    return contentLength;
  }

  @override
  Future<HttpClientResponse> fetchRange(int start, int end) async {
    if (_cancelled) throw StateError('Operation cancelled');
    
    final request = await _client!.getUrl(Uri.parse(url));
    _addHeaders(request);
    request.headers.add('Range', 'bytes=$start-$end');
    
    return await request.close();
  }

  void _addHeaders(HttpClientRequest request) {
    if (userAgent != null) {
      request.headers.set('User-Agent', userAgent!);
    }
    
    if (customHeaders != null) {
      customHeaders!.forEach((key, value) {
        request.headers.set(key, value);
      });
    }
  }

  String? _extractFileName(String? contentDisposition) {
    if (contentDisposition == null) return null;
    
    // Try to extract filename from Content-Disposition header
    final match = RegExp(r'filename[^;=\n]*=(([\"]).*?\2|[^;\n]*)').firstMatch(contentDisposition);
    if (match != null) {
      var fileName = match.group(1);
      if (fileName != null) {
        fileName = fileName.replaceAll(RegExp(r'^[^;=\n]*=(([\"])*?\2|[^;\n]*)'),'');
        return fileName;
      }
    }
    return null;
  }

  String? _extractFileNameFromUrl() {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) {
        return segments.last;
      }
    } catch (e) {
      // Ignore parse errors
    }
    return null;
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _client?.close(force: true);
  }

  @override
  Future<void> dispose() async {
    await _fileStatsController.close();
    _client?.close();
  }
}

/// Data source with custom headers for authenticated requests
class CustomHeaderDataSource extends HttpDataSource {
  CustomHeaderDataSource({
    required super.url,
    super.userAgent,
    super.proxyConfig,
    super.customHeaders,
  });
}

/// Detect MIME type from file content (first few bytes)
class MimeTypeDetector {
  static String? detectFromBytes(List<int> bytes) {
    if (bytes.length < 16) return null;
    
    // Video formats
    // MP4 files have 'ftyp' at offset 4-7, followed by brand at 8-11
    if (bytes.length >= 12 && _matchesSignature(bytes.sublist(4, 8), [0x66, 0x74, 0x79, 0x70])) {
      // Check for common MP4 brands: isom, mp41, mp42, avc1, iso2, etc.
      if (bytes.length >= 12) {
        final brand = String.fromCharCodes(bytes.sublist(8, 12));
        if (brand.startsWith('iso') || brand.startsWith('mp4') || 
            brand.startsWith('avc') || brand.startsWith('M4V') ||
            brand.startsWith('qt')) {
          return 'video/mp4';
        }
      }
      // Default to mp4 if ftyp is present
      return 'video/mp4';
    }
    if (_matchesSignature(bytes, [0x1A, 0x45, 0xDF, 0xA3])) {
      return 'video/webm';
    }
    if (_matchesSignature(bytes, [0x46, 0x4C, 0x56])) {
      return 'video/x-flv';
    }
    
    // Image formats
    if (_matchesSignature(bytes, [0xFF, 0xD8, 0xFF])) {
      return 'image/jpeg';
    }
    if (_matchesSignature(bytes, [0x89, 0x50, 0x4E, 0x47])) {
      return 'image/png';
    }
    if (_matchesSignature(bytes, [0x47, 0x49, 0x46, 0x38])) {
      return 'image/gif';
    }
    
    // Archive formats
    if (_matchesSignature(bytes, [0x50, 0x4B, 0x03, 0x04])) {
      return 'application/zip';
    }
    if (_matchesSignature(bytes, [0x52, 0x61, 0x72, 0x21])) {
      return 'application/x-rar-compressed';
    }
    
    // PDF
    if (_matchesSignature(bytes, [0x25, 0x50, 0x44, 0x46])) {
      return 'application/pdf';
    }
    
    return null;
  }
  
  static bool _matchesSignature(List<int> bytes, List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (int i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }
}
