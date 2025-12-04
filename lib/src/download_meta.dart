import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Represents a byte range [start, end] inclusive
class ByteRange {
  int start;
  int end;

  ByteRange(this.start, this.end);

  Map<String, int> toJson() => {'start': start, 'end': end};

  factory ByteRange.fromJson(Map<String, dynamic> json) =>
      ByteRange(json['start'] as int, json['end'] as int);

  @override
  String toString() => '[$start-$end]';
}

/// Manages download metadata and range tracking
class DownloadMeta {
  final String id;
  final int totalSize;
  final String localPath;
  final String metaPath;
  final String? originalUrl; // Store original URL for reverse lookup
  String? mimeType; // Detected MIME type
  String? fileName; // Extracted filename from URL or headers
  String? targetPath; // Final target path for file after download completes

  List<ByteRange> _ranges = [];
  bool _needsMerge =
      false; // Track if merge is needed (performance optimization)

  // For large files (>100MB), use bitmap instead
  Uint8List? _bitmap;
  static const int _blockSize = 64 * 1024; // 64KB blocks
  bool _useBitmap = false;

  DownloadMeta({
    required this.id,
    required this.totalSize,
    required this.localPath,
    required this.metaPath,
    this.originalUrl,
    this.mimeType,
    this.fileName,
  }) {
    // Use bitmap for files larger than 100MB
    if (totalSize > 100 * 1024 * 1024) {
      _useBitmap = true;
      final numBlocks = (totalSize / _blockSize).ceil();
      final numBytes = (numBlocks / 8).ceil();
      _bitmap = Uint8List(numBytes);
    }
  }

  /// Extract extension from original URL or MIME type
  String get extension {
    // Try from fileName first
    if (fileName != null && fileName!.contains('.')) {
      return fileName!.split('.').last.toLowerCase();
    }

    // Try from original URL
    if (originalUrl != null) {
      try {
        final uri = Uri.parse(originalUrl!);
        final path = uri.path;
        if (path.contains('.')) {
          final ext = path.split('.').last.toLowerCase();
          // Validate it's a reasonable extension
          if (ext.length <= 5 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
            return ext;
          }
        }
      } catch (_) {}
    }

    // Fallback from MIME type
    return switch (mimeType) {
      'video/mp4' => 'mp4',
      'video/webm' => 'webm',
      'video/x-matroska' => 'mkv',
      'video/x-flv' => 'flv',
      'video/quicktime' => 'mov',
      'audio/mpeg' => 'mp3',
      'audio/mp4' => 'm4a',
      'application/pdf' => 'pdf',
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      _ => 'mp4', // Default
    };
  }

  /// Get suggested filename for export
  String get suggestedFileName {
    if (fileName != null && fileName!.isNotEmpty) {
      return fileName!;
    }

    // Try to extract from URL
    if (originalUrl != null) {
      try {
        final uri = Uri.parse(originalUrl!);
        final segments = uri.pathSegments;
        if (segments.isNotEmpty) {
          final lastSegment = segments.last;
          // Decode URL encoding
          final decoded = Uri.decodeComponent(lastSegment);
          if (decoded.isNotEmpty && decoded.length < 200) {
            return decoded;
          }
        }
      } catch (_) {}
    }

    return '$id.$extension';
  }

  /// Add a downloaded range and merge with existing
  void addRange(int start, int end) {
    if (_useBitmap) {
      _addRangeToBitmap(start, end);
    } else {
      _addRangeToList(start, end);
    }
  }

  void _addRangeToList(int start, int end) {
    _ranges.add(ByteRange(start, end));
    _needsMerge = true;

    // Only merge if we have many fragments (performance optimization)
    // Otherwise, defer merging to save() to avoid O(n log n) on every chunk
    if (_ranges.length > 100) {
      _mergeRanges();
    }
  }

  void _addRangeToBitmap(int start, int end) {
    final startBlock = start ~/ _blockSize;
    final endBlock = end ~/ _blockSize;

    for (int block = startBlock; block <= endBlock; block++) {
      final byteIndex = block ~/ 8;
      final bitIndex = block % 8;
      _bitmap![byteIndex] |= (1 << bitIndex);
    }
  }

  /// Merge overlapping/adjacent ranges (O(n log n))
  void _mergeRanges() {
    if (_ranges.length <= 1) {
      _needsMerge = false;
      return;
    }

    // Sort by start position
    _ranges.sort((a, b) => a.start.compareTo(b.start));

    List<ByteRange> merged = [];
    ByteRange current = _ranges[0];

    for (int i = 1; i < _ranges.length; i++) {
      if (_ranges[i].start <= current.end + 1) {
        // Merge: extend current range
        current.end = max(current.end, _ranges[i].end);
      } else {
        // No overlap: save current and move to next
        merged.add(current);
        current = _ranges[i];
      }
    }
    merged.add(current);
    _ranges = merged;
    _needsMerge = false;
  }

  /// Check if a specific range is fully cached
  bool hasRange(int start, int end) {
    if (_useBitmap) {
      return _hasRangeInBitmap(start, end);
    }
    return _hasRangeInList(start, end);
  }

  bool _hasRangeInList(int start, int end) {
    // Merge if needed before checking
    if (_needsMerge) {
      _mergeRanges();
    }
    for (final range in _ranges) {
      if (start >= range.start && end <= range.end) {
        return true;
      }
    }
    return false;
  }

  bool _hasRangeInBitmap(int start, int end) {
    final startBlock = start ~/ _blockSize;
    final endBlock = end ~/ _blockSize;

    for (int block = startBlock; block <= endBlock; block++) {
      final byteIndex = block ~/ 8;
      final bitIndex = block % 8;
      if ((_bitmap![byteIndex] & (1 << bitIndex)) == 0) {
        return false; // This block is missing
      }
    }
    return true;
  }

  /// Check if download is complete
  bool get isComplete {
    if (_useBitmap) {
      final numBlocks = (totalSize / _blockSize).ceil();
      for (int block = 0; block < numBlocks; block++) {
        final byteIndex = block ~/ 8;
        final bitIndex = block % 8;
        if ((_bitmap![byteIndex] & (1 << bitIndex)) == 0) {
          return false;
        }
      }
      return true;
    }
    return _ranges.length == 1 &&
        _ranges[0].start == 0 &&
        _ranges[0].end >= totalSize - 1;
  }

  /// Get download progress (0.0 to 100.0)
  double get progress {
    if (_useBitmap) {
      int downloaded = 0;
      final numBlocks = (totalSize / _blockSize).ceil();
      for (int block = 0; block < numBlocks; block++) {
        final byteIndex = block ~/ 8;
        final bitIndex = block % 8;
        if ((_bitmap![byteIndex] & (1 << bitIndex)) != 0) {
          downloaded += _blockSize;
        }
      }
      return min(100.0, (downloaded / totalSize) * 100);
    }

    int downloaded = 0;
    for (final range in _ranges) {
      downloaded += range.end - range.start + 1;
    }
    return (downloaded / totalSize) * 100;
  }

  /// Save metadata to disk
  Future<void> save() async {
    // Merge ranges before saving (performance optimization)
    if (_needsMerge && !_useBitmap) {
      _mergeRanges();
    }

    final file = File(metaPath);

    if (_useBitmap) {
      // Save bitmap + extra info as binary with header
      final header = jsonEncode({
        'id': id,
        'totalSize': totalSize,
        'originalUrl': originalUrl,
        'mimeType': mimeType,
        'fileName': fileName,
        'targetPath': targetPath,
        'bitmapOffset': 0, // Placeholder
      });
      final headerBytes = utf8.encode(header);
      final headerLen = headerBytes.length;

      // Format: [4 bytes header length][header json][bitmap]
      final buffer = BytesBuilder();
      buffer.add([
        (headerLen >> 24) & 0xFF,
        (headerLen >> 16) & 0xFF,
        (headerLen >> 8) & 0xFF,
        headerLen & 0xFF,
      ]);
      buffer.add(headerBytes);
      buffer.add(_bitmap!);
      await file.writeAsBytes(buffer.takeBytes());
    } else {
      // Save JSON
      final json = jsonEncode({
        'id': id,
        'totalSize': totalSize,
        'originalUrl': originalUrl,
        'mimeType': mimeType,
        'fileName': fileName,
        'targetPath': targetPath,
        'ranges': _ranges.map((r) => r.toJson()).toList(),
      });
      await file.writeAsString(json);
    }
  }

  /// Load metadata from disk
  Future<void> load() async {
    final file = File(metaPath);
    if (!await file.exists()) return;

    try {
      if (_useBitmap) {
        // Load bitmap with header
        final bytes = await file.readAsBytes();
        if (bytes.length < 4) return;

        final headerLen =
            (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
        if (bytes.length < 4 + headerLen) return;

        final headerJson = utf8.decode(bytes.sublist(4, 4 + headerLen));
        final data = jsonDecode(headerJson) as Map<String, dynamic>;

        mimeType = data['mimeType'] as String?;
        fileName = data['fileName'] as String?;
        targetPath = data['targetPath'] as String?;

        _bitmap = Uint8List.fromList(bytes.sublist(4 + headerLen));
      } else {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        _ranges = (data['ranges'] as List)
            .map((r) => ByteRange.fromJson(r))
            .toList();
        mimeType = data['mimeType'] as String?;
        fileName = data['fileName'] as String?;
        targetPath = data['targetPath'] as String?;
        _needsMerge = false; // Data from disk is already merged
      }
    } catch (e) {
      print('Warning: Could not load metadata: $e');
    }
  }

  /// Get list of gaps (missing byte ranges) for background download
  /// Returns list of (start, end) tuples for missing ranges
  List<(int, int)> getDownloadGaps() {
    if (_useBitmap) {
      return _getGapsFromBitmap();
    }
    return _getGapsFromList();
  }

  List<(int, int)> _getGapsFromList() {
    // Ensure ranges are merged before finding gaps
    if (_needsMerge) {
      _mergeRanges();
    }

    final gaps = <(int, int)>[];

    if (_ranges.isEmpty) {
      // No data at all - entire file is a gap
      gaps.add((0, totalSize - 1));
      return gaps;
    }

    // Check gap at the start
    if (_ranges.first.start > 0) {
      gaps.add((0, _ranges.first.start - 1));
    }

    // Check gaps between ranges
    for (int i = 0; i < _ranges.length - 1; i++) {
      final gapStart = _ranges[i].end + 1;
      final gapEnd = _ranges[i + 1].start - 1;
      if (gapStart <= gapEnd) {
        gaps.add((gapStart, gapEnd));
      }
    }

    // Check gap at the end
    if (_ranges.last.end < totalSize - 1) {
      gaps.add((_ranges.last.end + 1, totalSize - 1));
    }

    return gaps;
  }

  List<(int, int)> _getGapsFromBitmap() {
    final gaps = <(int, int)>[];
    final numBlocks = (totalSize / _blockSize).ceil();

    int? gapStart;

    for (int block = 0; block < numBlocks; block++) {
      final byteIndex = block ~/ 8;
      final bitIndex = block % 8;
      final isComplete = (_bitmap![byteIndex] & (1 << bitIndex)) != 0;

      if (!isComplete && gapStart == null) {
        // Start of a gap
        gapStart = block * _blockSize;
      } else if (isComplete && gapStart != null) {
        // End of a gap
        final gapEnd = min(block * _blockSize - 1, totalSize - 1);
        gaps.add((gapStart, gapEnd));
        gapStart = null;
      }
    }

    // Handle gap at the end
    if (gapStart != null) {
      gaps.add((gapStart, totalSize - 1));
    }

    return gaps;
  }

  /// Get first byte position that is cached containing or after [position]
  /// Returns null if no cached data after position
  int? getNextCachedPosition(int position) {
    if (_useBitmap) {
      final startBlock = position ~/ _blockSize;
      final numBlocks = (totalSize / _blockSize).ceil();

      for (int block = startBlock; block < numBlocks; block++) {
        final byteIndex = block ~/ 8;
        final bitIndex = block % 8;
        if ((_bitmap![byteIndex] & (1 << bitIndex)) != 0) {
          return block * _blockSize;
        }
      }
      return null;
    }

    // For list-based tracking
    if (_needsMerge) {
      _mergeRanges();
    }

    for (final range in _ranges) {
      if (range.end >= position) {
        return max(range.start, position);
      }
    }
    return null;
  }
}
