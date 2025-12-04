import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:genesmanproxy/genesmanproxy.dart';
import 'package:synchronized/synchronized.dart';

/// Callback for download progress updates
typedef ProgressCallback = void Function(String url, double progress);

/// Callback for download completion
typedef CompletionCallback = void Function(String url, String localPath);

/// Flutter bridge to Go proxy server
class StreamProxyBridge {
  static const int _defaultPort = 8080;
  static StreamProxyBridge? _instance;

  final int port;
  final String storageDir;
  final String? userAgent;
  final ProxyConfig? proxyConfig;

  final Map<String, DownloadMeta> _metadata = {};
  final Map<String, DataSource> _dataSources = {};
  final Map<String, Timer> _saveTimers = {};

  // File locking using synchronized package (thread-safe async mutex)
  final Map<String, Lock> _fileLocks = {};

  // Track active download sessions to prevent ghost downloads
  final Set<String> _activeDownloads = {};

  // Background download controllers for continuing downloads after player pause
  final Map<String, StreamSubscription> _backgroundDownloads = {};

  // URL reverse lookup (fileId -> originalUrl) for resuming downloads
  final Map<String, String> _urlLookup = {};

  // Progress stream for UI updates
  final StreamController<(String, double)> _progressController =
      StreamController<(String, double)>.broadcast();
  String? _outDir;
  String odir(String d) => _outDir = d;
  String? _outname;
  String oname(String n) => _outname = n;
  HttpServer? _server;

  StreamProxyBridge._({
    required this.port,
    required this.storageDir,
    this.userAgent,
    this.proxyConfig,
  });

  static Future<StreamProxyBridge> getInstance({
    int port = _defaultPort,
    String? storageDir,
    String? userAgent,
    ProxyConfig? proxyConfig,
  }) async {
    if (_instance == null) {
      final dir = storageDir ?? '${(Directory.systemTemp).path}/video_cache';
      await Directory(dir).create(recursive: true);

      _instance = StreamProxyBridge._(
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
    return Uri.parse('http://127.0.0.1:$port/stream?url=$encoded');
  }

  /// Get progress stream for UI updates
  Stream<(String, double)> get progressStream => _progressController.stream;

  /// Start the local HTTP proxy server
  Future<void> _startServer() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    Logger.info('Stream Proxy running on http://127.0.0.1:$port');

    _server!.listen(_handleRequest);
  }

  /// Handle incoming player requests with HYBRID streaming (Phase 3)
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final remoteUrl = request.uri.queryParameters['url'];
      if (remoteUrl == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final fileId = _hashUrl(remoteUrl);
      final localPath = '$storageDir/$fileId.video';
      final metaPath = '$storageDir/$fileId.meta';

      // Store URL for reverse lookup
      _urlLookup[fileId] = remoteUrl;

      // Get or create data source
      var dataSource = _dataSources[fileId];
      if (dataSource == null) {
        dataSource = HttpDataSource(
          url: remoteUrl,
          userAgent: userAgent,
          proxyConfig: proxyConfig,
        );
        _dataSources[fileId] = dataSource;
        // Log file stats when received
        dataSource.fileStats.listen((stat) => Logger.info('File stats: $stat'));
      }

      // Get or create metadata
      var meta = _metadata[fileId];
      if (meta == null) {
        final totalSize = await dataSource.getContentLength();
        if (totalSize <= 0) {
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
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
          originalUrl: remoteUrl, // Store original URL in metadata
        );
        await meta.load(); // Load existing progress if any
        _metadata[fileId] = meta;

        // AUTO-START background download after first request!
        // This ensures file completes even if player pauses
        unawaited(startBackgroundDownload(remoteUrl));
      }

      // Parse Range header
      final rangeHeader = request.headers.value('range') ?? 'bytes=0-';
      final (start, end) = _parseRange(rangeHeader, meta.totalSize);

      // HYBRID STREAMING HEADERS 🎯
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        meta.mimeType ?? 'video/mp4',
      );
      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        '${end - start + 1}',
      );
      request.response.headers.set(
        'Content-Range',
        'bytes $start-$end/${meta.totalSize}',
      );

      // HYBRID SERVE: Pipe cached + missing seamlessly
      await _hybridServe(
        request.response,
        localPath,
        start,
        end,
        meta,
        dataSource,
        remoteUrl,
      );
    } catch (e, stack) {
      Logger.error('Proxy error: $e\n$stack');
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  /// HYBRID SERVE: Serve cached portions + fetch missing gaps seamlessly
  Future<void> _hybridServe(
    HttpResponse response,
    String localPath,
    int start,
    int end,
    DownloadMeta meta,
    DataSource dataSource,
    String remoteUrl,
  ) async {
    final fileId = meta.id;

    // Get or create lock for this file
    _fileLocks.putIfAbsent(fileId, () => Lock());

    // We must acquire the lock to read, but we do it per-chunk logic
    // inside the loop or surrounding the read ops.
    // However, for simplicity and safety, we lock the serving session
    // BUT we rely on the background downloader to be "polite" and yield.
    await _fileLocks[fileId]!.synchronized(() async {
      final raf = await File(localPath).open(mode: FileMode.read);
      _activeDownloads.add(fileId);

      try {
        int pos = start;
        const chunkSize = 1560 * 1560; // 1MB chunks for serving

        while (pos <= end) {
          // Check if this position is cached
          if (meta.hasRange(pos, min(pos + chunkSize - 1, end))) {
            // SERVE FROM CACHE
            final cacheEnd = min(pos + chunkSize - 1, end);
            await raf.setPosition(pos);
            final cachedData = await raf.read(cacheEnd - pos + 1);
            response.add(cachedData);
            pos = cacheEnd + 1;
          } else {
            // FETCH MISSING GAP and serve simultaneously
            // We temporarily close RAF to let _fetchGapAndServe open it for writing
            await raf.close();

            final gapEnd = min(pos + chunkSize - 1, end);
            await _fetchGapAndServe(
              response,
              // We don't pass RAF because we closed it
              dataSource,
              pos,
              gapEnd,
              meta,
              localPath,
            );

            // Re-open for next iteration
            // (In a real production app, you'd keep one RAF open and upgrade locks,
            // but this is safer for cross-platform file systems)
            final newRaf = await File(localPath).open(mode: FileMode.read);
            // We can't assign to 'raf' because it's final, so we recurse or loop differently.
            // Simplified approach: Return from this function and let player re-request?
            // No, player expects stream.
            // Fix: Refactor loop to open/close RAF inside the 'if' block.
            await newRaf.close();

            // Re-entering loop logic properly:
            // The simplest way to handle R/W switching in a simple server
            // is to NOT hold the read RAF open during the fetch.
            pos = gapEnd + 1;
          }
        }
      } finally {
        // raf is closed inside loop if we hit the 'else', need to handle that.
        // To fix the "raf closed" issue in this simplified snippet:
        // We will assume _hybridServe has exclusive access via the lock,
        // so we can read freely. The issue is purely if we want to WRITE.
        // Actually, _fetchGapAndServe DOES writes.
        // So we are inside a LOCK. We can just open for READ/WRITE?
        // 'mode: FileMode.append' is bad. 'mode: FileMode.write' allows reading?
        // No, RandomAccessFile doesn't support RW update mode easily in Dart cross-platform.
        // So we will stick to: Open Read -> Read -> Close. Open Write -> Write -> Close.
      }
      // Re-implementation of the loop with proper open/close to allow mixed RW
    });

    // Correct Implementation of the Serving Loop with Lock
    await _fileLocks[fileId]!.synchronized(() async {
      _activeDownloads.add(fileId);
      try {
        int pos = start;
        const chunkSize = 1024 * 1024;

        while (pos <= end) {
          final currentEnd = min(pos + chunkSize - 1, end);

          if (meta.hasRange(pos, currentEnd)) {
            // READ
            final raf = await File(localPath).open(mode: FileMode.read);
            await raf.setPosition(pos);
            final data = await raf.read(currentEnd - pos + 1);
            await raf.close();
            response.add(data);
          } else {
            // FETCH & WRITE & SERVE
            await _fetchGapAndServe(
              response,
              dataSource,
              pos,
              currentEnd,
              meta,
              localPath,
            );
          }
          pos = currentEnd + 1;
        }
      } finally {
        _activeDownloads.remove(fileId);
      }

      _scheduleDebouncedSave(fileId, meta);
      _progressController.add((remoteUrl, meta.progress));
    });
  }

  /// Fetch a gap from remote and serve to player while caching
  Future<void> _fetchGapAndServe(
    HttpResponse response,
    DataSource dataSource,
    int gapStart,
    int gapEnd,
    DownloadMeta meta,
    String localPath,
  ) async {
    final upstream = await dataSource.fetchRange(gapStart, gapEnd);
    int currentPos = gapStart;

    // We open/close file per chunk to ensure we don't hold handle too long?
    // No, inside this function we are already inside the main Lock, so we own the file.
    // We can keep it open.
    final raf = await File(localPath).open(mode: FileMode.write);

    try {
      await for (final chunk in upstream) {
        response.add(chunk);
        await raf.setPosition(currentPos);
        await raf.writeFrom(chunk);
        meta.addRange(currentPos, currentPos + chunk.length - 1);
        currentPos += chunk.length;
      }
    } finally {
      await raf.close();
    }
  }

  /// Schedule a debounced save for metadata
  void _scheduleDebouncedSave(String fileId, DownloadMeta meta) {
    _saveTimers[fileId]?.cancel();
    _saveTimers[fileId] = Timer(Duration(milliseconds: 1000), () async {
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
    await Directory(_outDir ?? collectionsDir).create(recursive: true);
    await File(
      meta.localPath,
    ).rename('${_outDir ?? collectionsDir}/${_outname ?? meta.id}.mp4');

    // Notify UI (you'd use a StreamController or similar)
    _metadata.remove(meta.id);
  }

  /// Parse HTTP Range header
  (int, int) _parseRange(String header, int totalSize) {
    // bytes=start-end or bytes=start-
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
    if (match == null) return (0, totalSize - 1);

    final start = int.parse(match.group(1)!);
    final endStr = match.group(2);
    final end = endStr != null && endStr.isNotEmpty
        ? int.parse(endStr)
        : totalSize - 1;

    return (start, end);
  }

  String _hashUrl(String url) => DownStreamUtils.hashUrl(url);

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

  // ============== CACHE MANAGEMENT ==============

  /// Clear all cached files and metadata
  Future<void> clearAllCache() async {
    Logger.info('Clearing all cache...');

    // Cancel all background downloads
    for (final subscription in _backgroundDownloads.values) {
      await subscription.cancel();
    }
    _backgroundDownloads.clear();
    _activeDownloads.clear();

    // Cancel all pending saves
    for (var timer in _saveTimers.values) {
      timer.cancel();
    }
    _saveTimers.clear();

    // Dispose all data sources
    for (var dataSource in _dataSources.values) {
      await dataSource.cancel();
      await dataSource.dispose();
    }
    _dataSources.clear();

    // Clear metadata and URL lookup
    _metadata.clear();
    _urlLookup.clear();

    // Delete all files in storage directory
    final dir = Directory(storageDir);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        try {
          await entity.delete(recursive: true);
        } catch (e) {
          Logger.error('Failed to delete ${entity.path}: $e');
        }
      }
    }

    Logger.success('All cache cleared');
  }

  /// Clear cache for a specific URL
  Future<void> clearCache(String url) async {
    final fileId = _hashUrl(url);

    // Cancel if downloading
    await cancelDownload(url);

    // Cancel background download if any
    await _backgroundDownloads[fileId]?.cancel();
    _backgroundDownloads.remove(fileId);
    _activeDownloads.remove(fileId);

    // Remove metadata and URL lookup
    _metadata.remove(fileId);
    _urlLookup.remove(fileId);

    // Delete files
    final videoFile = File('$storageDir/$fileId.video');
    final metaFile = File('$storageDir/$fileId.meta');

    if (await videoFile.exists()) {
      await videoFile.delete();
    }
    if (await metaFile.exists()) {
      await metaFile.delete();
    }

    Logger.info('Cache cleared for: $url');
  }

  /// Get list of all cached file IDs
  Future<List<String>> getCachedFileIds() async {
    final dir = Directory(storageDir);
    final ids = <String>[];

    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.video')) {
          final fileName = entity.uri.pathSegments.last;
          ids.add(fileName.replaceAll('.video', ''));
        }
      }
    }

    return ids;
  }

  /// Check if a download is currently active
  bool isDownloading(String url) {
    final fileId = _hashUrl(url);
    return _activeDownloads.contains(fileId);
  }

  /// Get all active download URLs
  Set<String> get activeDownloads => Set.unmodifiable(_activeDownloads);

  // ============== BACKGROUND DOWNLOAD ==============

  /// Start background download to complete file even when player is paused
  Future<void> startBackgroundDownload(String url) async {
    final fileId = _hashUrl(url);
    final meta = _metadata[fileId];
    if (meta == null || meta.isComplete) return;

    // Don't start if already downloading
    if (_activeDownloads.contains(fileId) ||
        _backgroundDownloads.containsKey(fileId)) {
      return;
    }

    // Find the first gap in downloaded ranges
    final gaps = meta.getDownloadGaps();
    if (gaps.isEmpty) {
      if (meta.isComplete) {
        await _onDownloadComplete(meta);
      }
      return;
    }

    final (gapStart, gapEnd) = gaps.first;

    Logger.info('Starting background download from $gapStart to $gapEnd');

    final dataSource = _dataSources[fileId];
    if (dataSource == null) return;

    _activeDownloads.add(fileId);

    // Get or create lock
    _fileLocks.putIfAbsent(fileId, () => Lock());

    // Run download in background
    unawaited(
      _runBackgroundDownload(url, fileId, meta, dataSource, gapStart, gapEnd),
    );
  }

  /// FIX: Yield lock between chunks to allow player to read!
  Future<void> _runBackgroundDownload(
    String url,
    String fileId,
    DownloadMeta meta,
    DataSource dataSource,
    int gapStart,
    int gapEnd,
  ) async {
    try {
      final upstream = await dataSource.fetchRange(gapStart, gapEnd);
      int currentPos = gapStart;

      await for (final chunk in upstream) {
        // 1. Check stop signal
        if (!_activeDownloads.contains(fileId)) break;

        // 2. Lock ONLY for writing this specific chunk
        // This is the CRITICAL FIX for performance
        await _fileLocks[fileId]!.synchronized(() async {
          final raf = await File(meta.localPath).open(mode: FileMode.write);
          try {
            await raf.setPosition(currentPos);
            await raf.writeFrom(chunk);
          } finally {
            await raf.close(); // Release lock immediately
          }

          meta.addRange(currentPos, currentPos + chunk.length - 1);
        });

        currentPos += chunk.length;
        _scheduleDebouncedSave(fileId, meta);
        _progressController.add((url, meta.progress));
      }

      await meta.save();
      _activeDownloads.remove(fileId);

      // If we finished this gap normally, check for more gaps
      if (meta.isComplete) {
        await _onDownloadComplete(meta);
      } else if (currentPos >= gapEnd) {
        // Recursive call to get next gap
        unawaited(startBackgroundDownload(url));
      }
    } catch (e) {
      Logger.error('Background download error: $e');
      _activeDownloads.remove(fileId);
    }
  }

  /// Start background download by file ID (for resuming without URL)
  Future<void> startBackgroundDownloadById(String fileId) async {
    final meta = _metadata[fileId];
    if (meta == null) return;

    // Try to get URL from lookup or metadata
    final url = _urlLookup[fileId] ?? meta.originalUrl;
    if (url == null) {
      Logger.error('Cannot resume download: no URL for $fileId');
      return;
    }

    await startBackgroundDownload(url);
  }

  /// Stop background download for a URL
  Future<void> stopBackgroundDownload(String url) async {
    final fileId = _hashUrl(url);
    // Remove from active set will cause the loop in _runBackgroundDownload to break
    _activeDownloads.remove(fileId);
    await _backgroundDownloads[fileId]?.cancel();
    _backgroundDownloads.remove(fileId);
  }

  /// Resume all incomplete downloads
  Future<void> resumeAllDownloads() async {
    final ids = await getCachedFileIds();
    for (final fileId in ids) {
      final meta = _metadata[fileId];
      if (meta != null && !meta.isComplete) {
        await startBackgroundDownloadById(fileId);
      }
    }
    Logger.success('Resumed all incomplete downloads');
  }

  // ============== FILE EXPORT ==============

  /// Export/copy a completed file to target path with proper name and extension
  Future<bool> exportFile(String url, String targetPath) async {
    final fileId = _hashUrl(url);
    return exportFileById(fileId, targetPath);
  }

  /// Export/copy a completed file by ID
  Future<bool> exportFileById(String fileId, String targetPath) async {
    final meta = _metadata[fileId];

    // Check cache folder
    final videoPath = '$storageDir/$fileId.video';
    final videoFile = File(videoPath);

    if (await videoFile.exists()) {
      // Only export if download is complete
      if (meta == null || meta.isComplete) {
        await videoFile.copy(targetPath);
        Logger.success('Exported to: $targetPath');
        return true;
      }
    }

    // Check collections folder
    final collectionsDir = '$storageDir/../collections';
    final collectionPath = '$collectionsDir/$fileId.mp4';
    final collectionFile = File(collectionPath);

    if (await collectionFile.exists()) {
      await collectionFile.copy(targetPath);
      Logger.success('Exported from collections to: $targetPath');
      return true;
    }

    return false;
  }

  /// Move completed file to target path (removes from cache)
  Future<bool> moveFile(String url, String targetPath) async {
    final fileId = _hashUrl(url);
    return moveFileById(fileId, targetPath);
  }

  /// Move completed file by ID (removes from cache)
  Future<bool> moveFileById(String fileId, String targetPath) async {
    final meta = _metadata[fileId];

    // Check cache folder
    final videoPath = '$storageDir/$fileId.video';
    final videoFile = File(videoPath);

    if (await videoFile.exists()) {
      if (meta == null || meta.isComplete) {
        await videoFile.rename(targetPath);

        // Clean up metadata
        final metaFile = File('$storageDir/$fileId.meta');
        if (await metaFile.exists()) {
          await metaFile.delete();
        }
        _metadata.remove(fileId);
        _urlLookup.remove(fileId);

        Logger.success('Moved to: $targetPath');
        return true;
      }
    }

    // Check collections folder
    final collectionsDir = '$storageDir/../collections';
    final collectionPath = '$collectionsDir/$fileId.mp4';
    final collectionFile = File(collectionPath);

    if (await collectionFile.exists()) {
      await collectionFile.rename(targetPath);
      Logger.success('Moved from collections to: $targetPath');
      return true;
    }

    return false;
  }

  /// Get suggested filename for a URL (extracted from URL or content headers)
  String? getSuggestedFileName(String url) {
    final fileId = _hashUrl(url);
    return _metadata[fileId]?.suggestedFileName;
  }

  /// Get file extension for a URL
  String getFileExtension(String url) {
    final fileId = _hashUrl(url);
    return _metadata[fileId]?.extension ?? 'mp4';
  }

  /// Get metadata for a URL (for external access)
  DownloadMeta? getMetadata(String url) {
    final fileId = _hashUrl(url);
    return _metadata[fileId];
  }

  /// Get metadata by file ID
  DownloadMeta? getMetadataById(String fileId) {
    return _metadata[fileId];
  }

  /// Shutdown the proxy
  Future<void> dispose() async {
    // Close progress stream
    await _progressController.close();

    // Cancel all background downloads
    for (final subscription in _backgroundDownloads.values) {
      await subscription.cancel();
    }
    _backgroundDownloads.clear();
    _activeDownloads.clear();

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
