import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Utility functions for DownStream
class DownStreamUtils {
  /// Hash URL to generate file ID using SHA-256
  /// Returns first 16 characters of the hex digest
  static String hashUrl(String url) {
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }
}
