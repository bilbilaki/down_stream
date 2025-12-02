import 'dart:io';
import 'package:genesmanproxy/genesmanproxy.dart';

/// Main API for the DownStream package
class DownStream {
  static DownStream? _instance;
  static StreamProxyBridge? _proxy;

  String? _storageDir;
  String? _collectionsDir;

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
      
      final dir = storageDir ?? '${Directory.systemTemp.path}/down_stream_cache';
      _instance!._storageDir = dir;
      _instance!._collectionsDir = '$dir/collections';
      
      await Directory(dir).create(recursive: true);
      await Directory(_instance!._collectionsDir!).create(recursive: true);
      
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
      throw StateError('DownStream not initialized. Call DownStream.init() first.');
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

  /// Get all downloads (both in-progress and completed)
  Future<List<DownloadInfo>> getAllDownloads() async {
    final downloads = <DownloadInfo>[];
    
    if (_storageDir == null) return downloads;
    
    final dir = Directory(_storageDir!);
    if (!await dir.exists()) return downloads;
    
    // Scan for .video and .meta files
    await for (final entity in dir.list()) {
      if (entity is File) {
        final path = entity.path;
        if (path.endsWith('.video')) {
          final id = path.split('/').last.replaceAll('.video', '');
          final metaPath = '$_storageDir/$id.meta';
          final metaExists = await File(metaPath).exists();
          
          final stat = await entity.stat();
          
          downloads.add(DownloadInfo(
            id: id,
            localPath: path,
            totalSize: stat.size,
            isComplete: !metaExists,
            progress: metaExists ? 0.0 : 100.0, // Simplified
          ));
        }
      }
    }
    
    // Scan collections folder
    if (_collectionsDir != null) {
      final collectionsDir = Directory(_collectionsDir!);
      if (await collectionsDir.exists()) {
        await for (final entity in collectionsDir.list()) {
          if (entity is File && entity.path.endsWith('.mp4')) {
            final id = entity.path.split('/').last.replaceAll('.mp4', '');
            final stat = await entity.stat();
            
            downloads.add(DownloadInfo(
              id: id,
              localPath: entity.path,
              totalSize: stat.size,
              isComplete: true,
              progress: 100.0,
            ));
          }
        }
      }
    }
    
    return downloads;
  }

  String _hashUrl(String url) => DownStreamUtils.hashUrl(url);

  /// Remove cached file and metadata by URL
  Future<void> removeCache(String url) async {
    final fileId = _hashUrl(url);
    await removeCacheById(fileId);
  }

  /// Remove cached file and metadata by file ID
  Future<void> removeCacheById(String fileId) async {
    if (_storageDir == null) return;
    
    final videoPath = '$_storageDir/$fileId.video';
    final metaPath = '$_storageDir/$fileId.meta';
    
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
    if (_collectionsDir != null) {
      final collectionPath = '$_collectionsDir/$fileId.mp4';
      final collectionFile = File(collectionPath);
      if (await collectionFile.exists()) {
        await collectionFile.delete();
      }
    }
  }

  /// Export a completed file to a target path
  Future<bool> exportFile(String url, String targetPath) async {
    if (_storageDir == null) return false;
    
    final fileId = _hashUrl(url);
    
    // Check collections folder first
    if (_collectionsDir != null) {
      final collectionPath = '$_collectionsDir/$fileId.mp4';
      final collectionFile = File(collectionPath);
      if (await collectionFile.exists()) {
        await collectionFile.copy(targetPath);
        return true;
      }
    }
    
    // Check cache folder
    final videoPath = '$_storageDir/$fileId.video';
    final videoFile = File(videoPath);
    if (await videoFile.exists()) {
      final metaPath = '$_storageDir/$fileId.meta';
      final metaExists = await File(metaPath).exists();
      
      // Only export if download is complete (no metadata file)
      if (!metaExists) {
        await videoFile.copy(targetPath);
        return true;
      }
    }
    
    return false;
  }

  /// Validate files on startup
  /// If a .video file exists but .meta is missing, treat as completed
  Future<void> _validateFiles() async {
    if (_storageDir == null) return;
    
    final dir = Directory(_storageDir!);
    if (!await dir.exists()) return;
    
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.video')) {
        final id = entity.path.split('/').last.replaceAll('.video', '');
        final metaPath = '$_storageDir/$id.meta';
        final metaExists = await File(metaPath).exists();
        
        // If video exists but no metadata, treat as imported/completed
        if (!metaExists) {
          Logger.success('Validated complete file: $id');
          // Optionally move to collections
          if (_collectionsDir != null) {
            final targetPath = '$_collectionsDir/$id.mp4';
            if (!await File(targetPath).exists()) {
              await entity.rename(targetPath);
              Logger.info('Moved to collections: $id');
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

  DownloadInfo({
    required this.id,
    required this.localPath,
    required this.totalSize,
    required this.isComplete,
    required this.progress,
  });

  @override
  String toString() =>
      'DownloadInfo(id: $id, size: $totalSize, complete: $isComplete, progress: $progress%)';
}
