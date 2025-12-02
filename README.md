# DownStream

A Flutter package that acts as a local proxy server to simultaneously stream, download, cache, and manage media/files with support for sparse (non-linear) access.

## Features

- 🎬 **Stream & Download Simultaneously**: Watch videos while they download
- 💾 **Sparse File Caching**: Efficient "Swiss Cheese" storage method for non-sequential downloads
- 🔄 **Resume Support**: Pause and resume downloads seamlessly
- 🌐 **Custom User-Agent**: Configure custom user agents for requests
- 🔒 **Proxy Support**: HTTP and SOCKS5 proxy configuration
- 🚫 **Cancellation**: Cancel downloads at any time
- 📊 **Progress Tracking**: Real-time download progress
- 🔍 **File Preview**: Get file info (name, size, type) before download completes
- 📦 **Collections Management**: Export and manage downloaded files
- 🎯 **Range Requests**: Full support for HTTP Range headers and seeking

## Getting Started

### Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  genesmanproxy: ^0.0.1
```

### Basic Usage

```dart
import 'package:genesmanproxy/genesmanproxy.dart';

// Initialize DownStream
await DownStream.init(
  port: 8080,  // Local proxy port
  storageDir: '/path/to/cache',  // Optional: custom cache directory
  userAgent: 'MyApp/1.0',  // Optional: custom user agent
);

// Get local proxy URL for streaming
final remoteUrl = 'https://example.com/video.mp4';
final localUrl = DownStream.instance.cache(remoteUrl);

// Use localUrl with your video player
// e.g., VideoPlayer.network(localUrl.toString())
```

### Advanced Configuration

#### With Proxy Support

```dart
await DownStream.init(
  port: 8080,
  proxyConfig: ProxyConfig(
    host: 'proxy.example.com',
    port: 8080,
    type: ProxyType.http,
    username: 'user',  // Optional
    password: 'pass',  // Optional
  ),
);
```

#### With Custom Headers (e.g., for authenticated downloads)

```dart
final dataSource = CustomHeaderDataSource(
  url: 'https://api.example.com/private/video.mp4',
  customHeaders: {
    'Authorization': 'Bearer YOUR_TOKEN',
    'X-API-Key': 'YOUR_API_KEY',
  },
);
```

### Progress Tracking

```dart
// Get download progress (0.0 to 100.0)
final progress = DownStream.instance.getProgress(remoteUrl);
print('Download progress: $progress%');

// Listen to file stats (name, size, mime type)
DownStream.instance.getFileStats(remoteUrl)?.listen((stat) {
  print('File: ${stat.fileName}');
  print('Size: ${stat.totalSize} bytes');
  print('Type: ${stat.mimeType}');
});
```

### Managing Downloads

```dart
// Get all downloads (in-progress and completed)
final downloads = await DownStream.instance.getAllDownloads();
for (final download in downloads) {
  print('${download.id}: ${download.progress}% complete');
}

// Cancel a download
await DownStream.instance.cancelDownload(remoteUrl);

// Remove cached file
await DownStream.instance.removeCache(remoteUrl);

// Export completed file to a custom location
final success = await DownStream.instance.exportFile(
  remoteUrl,
  '/path/to/export/video.mp4',
);
```

### Logging Configuration

```dart
// Enable or disable logging (enabled by default)
Logger.setEnabled(false);  // Disable all logs
Logger.setEnabled(true);   // Enable logs
```

### Cleanup

```dart
// Shutdown DownStream when done
await DownStream.instance.dispose();
```

## How It Works

### Phase 1: Core Proxy
- Binds a local HTTP server on `127.0.0.1:PORT`
- Intercepts video player requests
- Forwards Range headers to remote server
- Streams response back to player

### Phase 2: Sparse Storage
- Creates a sparse file of full size on first request
- Writes downloaded chunks at correct positions
- Tracks downloaded ranges using efficient bitmap or list structure
- Merges overlapping/adjacent ranges automatically

### Phase 3: Data Source Layer
- Abstract `DataSource` interface for different sources
- `HttpDataSource` for standard web URLs
- `CustomHeaderDataSource` for authenticated requests
- File preview with MIME type detection

### Phase 4: Go Integration (Optional)
- Go-based proxy backend for performance
- Dart FFI bridge for Go-Dart communication
- Optional for advanced use cases

### Phase 5: Collections API
- High-level API for easy integration
- File validation on startup
- Export completed downloads
- Clean management interface

## Architecture

```
┌─────────────┐
│ Video Player│
└──────┬──────┘
       │ http://127.0.0.1:8080/stream?url=...
       ▼
┌─────────────┐     ┌──────────────┐
│ Proxy Server│────▶│ Data Source  │
└──────┬──────┘     └──────┬───────┘
       │                    │
       │ Cache              │ Fetch
       ▼                    ▼
┌─────────────┐     ┌──────────────┐
│   Sparse    │     │ Remote Server│
│   Storage   │     └──────────────┘
└─────────────┘
```

## Performance

- **Bitmap Optimization**: For files > 100MB, uses bitmap tracking instead of range lists
- **Debounced Saves**: Metadata saved every 500ms to reduce I/O
- **Sparse Files**: No wasted disk space for incomplete downloads
- **Zero-Copy Streaming**: Direct pipe from network to player and disk

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
