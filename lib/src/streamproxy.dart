import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:genesmanproxy/genesmanproxy.dart';
import 'logger.dart';

/// Flutter bridge to Go proxy server
class StreamProxyBridge {
  static const int _defaultPort = 8080;
  static StreamProxyBridge?  _instance;

  final int port;
  final String storageDir;
  final String? userAgent;
  final ProxyConfig? proxyConfig;
  
  final Map<String, DownloadMeta> _metadata = {};
  final Map<String, DataSource> _dataSources = {};
  final Map<String, Timer> _saveTimers = {};
  
  HttpServer? _server;

  StreamProxyBridge._({
    required this.port,
    required this.storageDir,
    this.userAgent,
    this.proxyConfig,
  });

  static Future<StreamProxyBridge> getInstance({
    int port = _defaultPort,
    String?  storageDir,
    String? userAgent,
    ProxyConfig? proxyConfig,
  }) async {
    if (_instance == null) {
      final dir = storageDir ??  
        '${(await Directory.systemTemp). path}/video_cache';
      await Directory(dir).create(recursive: true);
      
      _instance = StreamProxyBridge. _(
        port: port,
        storageDir: dir,
        userAgent: userAgent,
        proxyConfig: proxyConfig,
      );
      await _instance!._startServer();
    }
    return _instance!;
  }

  /// Get proxy URL for a remote video
  Uri getProxyUrl(String remoteUrl) {
    final encoded = Uri.encodeComponent(remoteUrl);
    return Uri. parse('http://127.0.0. 1:$port/stream? url=$encoded');
  }

  /// Start the local HTTP proxy server
  Future<void> _startServer() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    Logger.info('Stream Proxy running on http://127.0.0.1:$port');

    _server! .listen(_handleRequest);
  }

  /// Handle incoming player requests
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final remoteUrl = request. uri.queryParameters['url'];
      if (remoteUrl == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final fileId = _hashUrl(remoteUrl);
      final localPath = '$storageDir/$fileId.video';
      final metaPath = '$storageDir/$fileId.meta';

      // Get or create data source
      var dataSource = _dataSources[fileId];
      if (dataSource == null) {
        dataSource = HttpDataSource(
          url: remoteUrl,
          userAgent: userAgent,
          proxyConfig: proxyConfig,
        );
        _dataSources[fileId] = dataSource;
      }

      // Get or create metadata
      var meta = _metadata[fileId];
      if (meta == null) {
        final totalSize = await dataSource.getContentLength();
        if (totalSize <= 0) {
          request.response.statusCode = HttpStatus.badGateway;
          await request.response. close();
          return;
        }

        // Create sparse file
        final file = File(localPath);
        final raf = await file.open(mode: FileMode.write);
        await raf.truncate(totalSize);
        await raf.close();

        meta = DownloadMeta(
          id: fileId,
          totalSize: totalSize,
          localPath: localPath,
          metaPath: metaPath,
        );
        await meta.load(); // Load existing progress if any
        _metadata[fileId] = meta;
      }

      // Parse Range header
      final rangeHeader = request. headers. value('range') ?? 'bytes=0-';
      final (start, end) = _parseRange(rangeHeader, meta.totalSize);

      // Set response headers (CRITICAL: 206 Partial Content!)
      request.response.statusCode = HttpStatus.partialContent;
      request. response.headers.add('Accept-Ranges', 'bytes');
      request.response.headers.add('Content-Type', 'video/mp4');
      request. response.headers.add('Content-Length', '${end - start + 1}');
      request.response.headers.add(
        'Content-Range', 
        'bytes $start-$end/${meta.totalSize}'
      );

      if (meta.hasRange(start, end)) {
        // Serve from cache
        await _serveFromDisk(request. response, localPath, start, end);
      } else {
        // Fetch, cache, and serve
        await _fetchAndServe(
          request.response, 
          remoteUrl, 
          localPath, 
          start, 
          end, 
          meta,
        );
      }
    } catch (e) {
      Logger.error('Proxy error: $e');
      request. response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  /// Serve cached content from disk
  Future<void> _serveFromDisk(
    HttpResponse response, 
    String path, 
    int start, 
    int end,
  ) async {
    final file = File(path);
    final raf = await file. open(mode: FileMode.read);
    await raf.setPosition(start);
    
    final length = end - start + 1;
    final data = await raf. read(length);
    response.add(data);
    
    await raf. close();
  }

  /// Fetch from remote, cache to disk, and stream to player simultaneously
  Future<void> _fetchAndServe(
    HttpResponse response,
    String url,
    String localPath,
    int start,
    int end,
    DownloadMeta meta,
  ) async {
    final fileId = meta.id;
    final dataSource = _dataSources[fileId];
    if (dataSource == null) {
      throw StateError('DataSource not found for $fileId');
    }

    final upstream = await dataSource.fetchRange(start, end);
    
    // Open file for sparse writing
    final file = File(localPath);
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    
    int currentPos = start;
    
    await for (final chunk in upstream) {
      // 1. Send to player
      response.add(chunk);
      
      // 2. Write to disk at correct position (sparse write!)
      await raf.setPosition(currentPos);
      await raf.writeFrom(chunk);
      
      // 3. Update metadata
      meta.addRange(currentPos, currentPos + chunk.length - 1);
      currentPos += chunk.length;
      
      // 4. Debounced save (save every 500ms)
      _scheduleDebouncedSave(fileId, meta);
    }
    
    await raf.close();
    
    // Cancel any pending save and do final save
    _saveTimers[fileId]?.cancel();
    _saveTimers.remove(fileId);
    await meta.save();
    
    // Check if download is complete
    if (meta.isComplete) {
      await _onDownloadComplete(meta);
    }
  }

  /// Schedule a debounced save for metadata
  void _scheduleDebouncedSave(String fileId, DownloadMeta meta) {
    _saveTimers[fileId]?.cancel();
    _saveTimers[fileId] = Timer(const Duration(milliseconds: 500), () async {
      await meta.save();
      _saveTimers.remove(fileId);
    });
  }

  /// Handle completed download
  Future<void> _onDownloadComplete(DownloadMeta meta) async {
    Logger.success('Download complete: ${meta.id}');
    
    // Delete metadata file
    await File(meta.metaPath).delete();
    
    // Move to collections folder
    final collectionsDir = '$storageDir/../collections';
    await Directory(collectionsDir).create(recursive: true);
    await File(meta.localPath).rename('$collectionsDir/${meta.id}.mp4');
    
    // Notify UI (you'd use a StreamController or similar)
    _metadata.remove(meta. id);
  }

  /// Parse HTTP Range header
  (int, int) _parseRange(String header, int totalSize) {
    // bytes=start-end or bytes=start-
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
    if (match == null) return (0, totalSize - 1);
    
    final start = int.parse(match.group(1)!);
    final endStr = match.group(2);
    final end = endStr != null && endStr.isNotEmpty 
      ? int. parse(endStr) 
      : totalSize - 1;
    
    return (start, end);
  }

  String _hashUrl(String url) {
    // Use SHA-256 for secure, collision-resistant hashing
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  /// Get download progress for a URL
  double getProgress(String url) {
    final fileId = _hashUrl(url);
    return _metadata[fileId]?.progress ?? 0.0;
  }

  /// Cancel a download task
  Future<void> cancelDownload(String url) async {
    final fileId = _hashUrl(url);
    
    // Cancel data source
    final dataSource = _dataSources[fileId];
    if (dataSource != null) {
      await dataSource.cancel();
      _dataSources.remove(fileId);
    }
    
    // Cancel pending save
    _saveTimers[fileId]?.cancel();
    _saveTimers.remove(fileId);
    
    Logger.cancel('Download cancelled: $url');
  }

  /// Get file stats for a URL
  Stream<FileStat>? getFileStats(String url) {
    final fileId = _hashUrl(url);
    return _dataSources[fileId]?.fileStats;
  }

  /// Shutdown the proxy
  Future<void> dispose() async {
    // Cancel all pending saves
    for (var timer in _saveTimers.values) {
      timer.cancel();
    }
    _saveTimers.clear();
    
    // Dispose all data sources
    for (var dataSource in _dataSources.values) {
      await dataSource.dispose();
    }
    _dataSources.clear();
    
    await _server?.close();
    _instance = null;
  }
}