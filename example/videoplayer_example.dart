import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:genesmanproxy/genesmanproxy.dart';
import 'package:video_player/video_player.dart'; // Add video_player to pubspec

void main() {
  runApp(const MaterialApp(home: DownStreamExample()));
}

class DownStreamExample extends StatefulWidget {
  const DownStreamExample({super.key});

  @override
  State<DownStreamExample> createState() => _DownStreamExampleState();
}

class _DownStreamExampleState extends State<DownStreamExample> {
  final _urlController = TextEditingController(
    text: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'
  );
  
  VideoPlayerController? _videoController;
  List<DownloadInfo> _downloads = [];
  Timer? _refreshTimer;
  
  @override
  void initState() {
    super.initState();
    _initDownStream();
    // Poll for UI updates (simpler than listening to stream for list changes)
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshList());
  }

  Future<void> _initDownStream() async {
    // 1. Initialize the Engine
    await DownStream.init(
      port: 8080, 
      userAgent: 'MyCoolApp/1.0',
    );
    _refreshList();
  }

  Future<void> _refreshList() async {
    final list = await DownStream.instance.getAllDownloads();
    if (mounted) setState(() => _downloads = list);
  }

  // ================= ACTION HANDLERS =================

  Future<void> _playAndCache() async {
    final url = _urlController.text;
    if (url.isEmpty) return;

    // 2. Get the Local Proxy URL
    // This returns http://127.0.0.1:8080/stream?url=...
    final proxyUrl = DownStream.instance.cache(url);

    // 3. Initialize Video Player with Proxy URL
    _videoController?.dispose();
    _videoController = VideoPlayerController.networkUrl(proxyUrl)
      ..initialize().then((_) {
        setState(() {});
        _videoController!.play();
      });
  }

  Future<void> _startBackgroundDownload(String url) async {
    // 4. Start downloading without playing
    // Useful for "Make Available Offline" buttons
    await DownStream.instance.startBackgroundDownload(url);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Background download started')),
    );
  }

  Future<void> _exportFile(DownloadInfo item) async {
    if (!item.isComplete) return;

    // 5. Export to Documents
    final docsDir = Directory.systemTemp; // Using temp for example
    final targetPath = '${docsDir.path}/${item.fileName ?? "video.mp4"}';
    
    final success = await DownStream.instance.exportFile(item.originalUrl ?? "", targetPath);
    
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to $targetPath')),
      );
    }
  }

  Future<void> _clearAll() async {
    await _videoController?.pause();
    _videoController?.dispose();
    _videoController = null;
    
    // 6. Nuke everything
    await DownStream.instance.clearAllCache();
    await _refreshList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DownStream Manager')),
      body: Column(
        children: [
          // Input Section
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(child: TextField(controller: _urlController)),
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: _playAndCache,
                  tooltip: "Stream & Cache",
                ),
                IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () => _startBackgroundDownload(_urlController.text),
                  tooltip: "Background Download",
                ),
              ],
            ),
          ),

          // Player Section
          if (_videoController != null && _videoController!.value.isInitialized)
            AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            ),

          const Divider(),
          
          // Downloads List
          Expanded(
            child: ListView.builder(
              itemCount: _downloads.length,
              itemBuilder: (context, index) {
                final item = _downloads[index];
                final isDownloading = DownStream.instance.isDownloading(item.originalUrl ?? "");

                return ListTile(
                  title: Text(item.fileName ?? item.id),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.formattedSize),
                      LinearProgressIndicator(value: item.progress / 100),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isDownloading) 
                        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      else if (!item.isComplete)
                         IconButton(
                          icon: const Icon(Icons.play_for_work),
                          onPressed: () => DownStream.instance.startBackgroundDownload(item.originalUrl!),
                        ),
                      if (item.isComplete)
                        IconButton(
                          icon: const Icon(Icons.save_alt),
                          onPressed: () => _exportFile(item),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => DownStream.instance.removeCacheById(item.id),
                      ),
                    ],
                  ),
                  onTap: () {
                    // Resume playback from this cached item
                    if (item.originalUrl != null) {
                      _urlController.text = item.originalUrl!;
                      _playAndCache();
                    }
                  },
                );
              },
            ),
          ),
          
          TextButton(
            onPressed: _clearAll, 
            child: const Text("Clear All Cache (Debug)"),
          ),
        ],
      ),
    );
  }
  
  @override
  void dispose() {
    _videoController?.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }
}