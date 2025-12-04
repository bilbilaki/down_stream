import 'dart:io';
import 'package:genesmanproxy/genesmanproxy.dart';
import 'package:path/path.dart' as p;

/// Main API for the DownStream package
class DownStream {
  static DownStream? _instance;
  static StreamProxyBridge? _proxy;

  String? storageDir;
  String? collectionsDir;

  DownStream._();

  /// Initialize DownStream
  static Future<DownStream> init({
    int port = 8080,
    String? storageDir,
    String? userAgent,
    ProxyConfig? proxyConfig,
  }) async {
    if (_instance == null) {
      _instance = DownStream._();

      final dir =
          storageDir ?? '${Directory.systemTemp.path}/down_stream_cache';
      _instance!.storageDir = dir;
      _instance!.collectionsDir = '$dir/collections';

      await Directory(dir).create(recursive: true);
      await Directory(_instance!.collectionsDir!).create(recursive: true);

      _proxy = await StreamProxyBridge.getInstance(
        port: port,
        storageDir: dir,
        userAgent: userAgent,
        proxyConfig: proxyConfig,
      );

      // Validate existing files on startup
      await _instance!._validateFiles();
    }
    return _instance!;
  }

  /// Get singleton instance (must call init first)
  static DownStream get instance {
    if (_instance == null) {
      throw StateError(
        'DownStream not initialized. Call DownStream.init() first.',
      );
    }
    return _instance!;
  }

  /// Cache a URL and return the local proxy URL for playback
  Uri cache(String remoteUrl) {
    if (_proxy == null) {
      throw StateError('DownStream not initialized');
    }
    return _proxy!.getProxyUrl(remoteUrl);
  }

  /// Get download progress for a URL (0.0 to 100.0)
  double getProgress(String url) {
    if (_proxy == null) return 0.0;
    return _proxy!.getProgress(url);
  }

  /// Get progress stream for UI updates
  /// Emits (url, progress) tuples
  Stream<(String, double)>? get progressStream => _proxy?.progressStream;

  /// Cancel a download task
  Future<void> cancelDownload(String url) async {
    if (_proxy == null) return;
    await _proxy!.cancelDownload(url);
  }

  /// Get file statistics (preview info) for a URL
  Stream<FileStat>? getFileStats(String url) {
    if (_proxy == null) return null;
    return _proxy!.getFileStats(url);
  }

  // ============== CACHE MANAGEMENT ==============

  /// Clear ALL cache (files + metadata). Fixes ghost downloads from crashed sessions.
  Future<void> clearAllCache() async {
    if (_proxy == null) return;
    await _proxy!.clearAllCache();
    Logger.success('All cache cleared globally');
  }

  /// Resume/complete ALL incomplete downloads in background
  Future<void> resumeAllDownloads() async {
    if (_proxy == null) return;
    await _proxy!.resumeAllDownloads();
  }

  /// Start background download for a URL (completes file even when player pauses)
  Future<void> startBackgroundDownload(String url) async {
    if (_proxy == null) return;
    await _proxy!.startBackgroundDownload(url);
  }

  /// Stop background download for a URL
  Future<void> stopBackgroundDownload(String url) async {
    if (_proxy == null) return;
    await _proxy!.stopBackgroundDownload(url);
  }

  /// Check if a URL is currently being downloaded
  bool isDownloading(String url) {
    if (_proxy == null) return false;
    return _proxy!.isDownloading(url);
  }

  /// Get all downloads (both in-progress and completed)
  Future<List<DownloadInfo>> getAllDownloads() async {
    final downloads = <DownloadInfo>[];

    if (storageDir == null || _proxy == null) return downloads;

    // Get from proxy (accurate progress)
    final ids = await _proxy!.getCachedFileIds();
    for (final id in ids) {
      final meta = _proxy!.getMetadataById(id);
      final path = '$storageDir/$id.video';
      final file = File(path);

      if (await file.exists()) {
        final stat = await file.stat();
        downloads.add(
          DownloadInfo(
            id: id,
            localPath: path,
            totalSize: meta?.totalSize ?? stat.size,
            isComplete: meta == null || meta.isComplete,
            progress: meta?.progress ?? 100.0,
            fileName: meta?.suggestedFileName,
            originalUrl: meta?.originalUrl,
          ),
        );
      }
    }

    // Scan collections folder
    if (collectionsDir != null) {
      final collectionsDirm = Directory(collectionsDir!);
      if (await collectionsDirm.exists()) {
        await for (final entity in collectionsDirm.list()) {
          if (entity is File &&
              (entity.path.endsWith('.mp4') ||
                  entity.path.endsWith('.mkv') ||
                  entity.path.endsWith('.webm'))) {
            final fileName = p.basename(entity.path);
            final id = p.basenameWithoutExtension(fileName);

            // Skip if already added from cache
            if (downloads.any((d) => d.id == id)) continue;

            final stat = await entity.stat();
            downloads.add(
              DownloadInfo(
                id: id,
                localPath: entity.path,
                totalSize: stat.size,
                isComplete: true,
                progress: 100.0,
                fileName: fileName,
              ),
            );
          }
        }
      }
    }

    return downloads;
  }

  /// Remove cached file and metadata by URL
  Future<void> removeCache(String url) async {
    if (_proxy == null) return;
    await _proxy!.clearCache(url);
  }

  /// Remove cached file and metadata by file ID
  Future<void> removeCacheById(String fileId) async {
    if (storageDir == null) return;

    final videoPath = '$storageDir/$fileId.video';
    final metaPath = '$storageDir/$fileId.meta';

    // Delete video file
    final videoFile = File(videoPath);
    if (await videoFile.exists()) {
      await videoFile.delete();
    }

    // Delete metadata file
    final metaFile = File(metaPath);
    if (await metaFile.exists()) {
      await metaFile.delete();
    }

    // Check collections folder
    if (collectionsDir != null) {
      final collectionsDirm = Directory(collectionsDir!);
      if (await collectionsDirm.exists()) {
        await for (final entity in collectionsDirm.list()) {
          if (entity is File &&
              p.basenameWithoutExtension(entity.path) == fileId) {
            await entity.delete();
            break;
          }
        }
      }
    }
  }

  // ============== FILE EXPORT ==============

  /// Export a completed file to a target path (copy)
  Future<bool> exportFile(String url, String targetPath) async {
    if (_proxy == null) return false;
    return _proxy!.exportFile(url, targetPath);
  }

  /// Export a completed file by ID to a target path (copy)
  Future<bool> exportFileById(String fileId, String targetPath) async {
    if (_proxy == null) return false;
    return _proxy!.exportFileById(fileId, targetPath);
  }

  /// Move a completed file to a target path (removes from cache)
  Future<bool> moveFile(String url, String targetPath) async {
    if (_proxy == null) return false;
    return _proxy!.moveFile(url, targetPath);
  }

  /// Move a completed file by ID to a target path (removes from cache)
  Future<bool> moveFileById(String fileId, String targetPath) async {
    if (_proxy == null) return false;
    return _proxy!.moveFileById(fileId, targetPath);
  }

  /// Export with automatic filename based on URL/headers
  /// Returns the full path where file was saved, or null if failed
  Future<String?> exportWithAutoName(String url, String targetDir) async {
    if (_proxy == null) return null;

    final fileName = _proxy!.getSuggestedFileName(url);
    if (fileName == null) return null;

    final targetPath = p.join(targetDir, fileName);
    final success = await _proxy!.exportFile(url, targetPath);
    return success ? targetPath : null;
  }

  /// Move with automatic filename based on URL/headers
  /// Returns the full path where file was moved, or null if failed
  Future<String?> moveWithAutoName(String url, String targetDir) async {
    if (_proxy == null) return null;

    final fileName = _proxy!.getSuggestedFileName(url);
    if (fileName == null) return null;

    // Ensure proper extension
    final ext = _proxy!.getFileExtension(url);
    final finalName = fileName.contains('.') ? fileName : '$fileName.$ext';

    final targetPath = p.join(targetDir, finalName);
    final success = await _proxy!.moveFile(url, targetPath);
    return success ? targetPath : null;
  }

  /// Get suggested filename for a URL
  String? getSuggestedFileName(String url) {
    return _proxy?.getSuggestedFileName(url);
  }

  /// Get file extension for a URL
  String getFileExtension(String url) {
    return _proxy?.getFileExtension(url) ?? 'mp4';
  }

  /// Get download metadata for a URL
  DownloadMeta? getMetadata(String url) {
    return _proxy?.getMetadata(url);
  }

  // ============== DOWNLOAD TARGET PATH ==============

  /// Set target path for a download (where file will be moved after completion)
  /// Call this before or during download to specify final destination
  void setDownloadTarget(String url, String targetPath) {
    if (_proxy == null) return;
    _proxy!.setDownloadTarget(url, targetPath);
  }

  /// Set target path for a download by file ID
  void setDownloadTargetById(String fileId, String targetPath) {
    if (_proxy == null) return;
    _proxy!.setDownloadTargetById(fileId, targetPath);
  }

  /// Validate files on startup
  /// If a .video file exists but .meta is missing, treat as completed
  Future<void> _validateFiles() async {
    if (storageDir == null) return;

    final dir = Directory(storageDir!);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.video')) {
        final id = p
            .basenameWithoutExtension(entity.path)
            .replaceAll('.video', '');
        final metaPath = '$storageDir/$id.meta';
        final metaExists = await File(metaPath).exists();

        // If video exists but no metadata, treat as imported/completed
        if (!metaExists) {
          Logger.success('Validated complete file: $id');
          // Optionally move to collections
          if (collectionsDir != null) {
            final targetPath = '$collectionsDir/$id.mp4';
            if (!await File(targetPath).exists()) {
              try {
                await entity.rename(targetPath);
                Logger.info('Moved to collections: $id');
              } catch (e) {
                Logger.error('Failed to move to collections: $e');
              }
            }
          }
        }
      }
    }
  }

  /// Shutdown DownStream
  Future<void> dispose() async {
    await _proxy?.dispose();
    _proxy = null;
    _instance = null;
  }
}

/// Download information
class DownloadInfo {
  final String id;
  final String localPath;
  final int totalSize;
  final bool isComplete;
  final double progress;
  final String? fileName;
  final String? originalUrl;

  DownloadInfo({
    required this.id,
    required this.localPath,
    required this.totalSize,
    required this.isComplete,
    required this.progress,
    this.fileName,
    this.originalUrl,
  });

  /// Format file size for display
  String get formattedSize {
    if (totalSize < 1024) return '$totalSize B';
    if (totalSize < 1024 * 1024) {
      return '${(totalSize / 1024).toStringAsFixed(1)} KB';
    }
    if (totalSize < 1024 * 1024 * 1024) {
      return '${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(totalSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  String toString() =>
      'DownloadInfo(id: $id, size: $formattedSize, complete: $isComplete, progress: ${progress.toStringAsFixed(1)}%)';
}
