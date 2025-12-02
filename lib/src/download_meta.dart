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

  List<ByteRange> _ranges = [];
  
  // For large files (>100MB), use bitmap instead
  Uint8List? _bitmap;
  static const int _blockSize = 64 * 1024; // 64KB blocks
  bool _useBitmap = false;

  DownloadMeta({
    required this.id,
    required this.totalSize,
    required this.localPath,
    required this.metaPath,
  }) {
    // Use bitmap for files larger than 100MB
    if (totalSize > 100 * 1024 * 1024) {
      _useBitmap = true;
      final numBlocks = (totalSize / _blockSize).ceil();
      final numBytes = (numBlocks / 8).ceil();
      _bitmap = Uint8List(numBytes);
    }
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
    _mergeRanges();
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
    if (_ranges.length <= 1) return;

    // Sort by start position
    _ranges.sort((a, b) => a.start.compareTo(b.start));

    List<ByteRange> merged = [];
    ByteRange current = _ranges[0];

    for (int i = 1; i < _ranges.length; i++) {
      if (_ranges[i].start <= current.end + 1) {
        // Merge: extend current range
        current. end = max(current.end, _ranges[i].end);
      } else {
        // No overlap: save current and move to next
        merged.add(current);
        current = _ranges[i];
      }
    }
    merged.add(current);
    _ranges = merged;
  }

  /// Check if a specific range is fully cached
  bool hasRange(int start, int end) {
    if (_useBitmap) {
      return _hasRangeInBitmap(start, end);
    }
    return _hasRangeInList(start, end);
  }

  bool _hasRangeInList(int start, int end) {
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
        _ranges[0]. start == 0 &&
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
    final file = File(metaPath);
    
    if (_useBitmap) {
      // Save bitmap directly
      await file. writeAsBytes(_bitmap!);
    } else {
      // Save JSON
      final json = jsonEncode({
        'id': id,
        'totalSize': totalSize,
        'ranges': _ranges. map((r) => r.toJson()). toList(),
      });
      await file.writeAsString(json);
    }
  }

  /// Load metadata from disk
  Future<void> load() async {
    final file = File(metaPath);
    if (! await file.exists()) return;

    try {
      if (_useBitmap) {
        _bitmap = await file. readAsBytes();
      } else {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        _ranges = (data['ranges'] as List)
            .map((r) => ByteRange.fromJson(r))
            . toList();
      }
    } catch (e) {
      print('Warning: Could not load metadata: $e');
    }
  }
}