import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:genesmanproxy/genesmanproxy.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // 1. Important for MediaKit
  runApp(const MaterialApp(home: DownStreamMediaKitExample()));
}

class DownStreamMediaKitExample extends StatefulWidget {
  const DownStreamMediaKitExample({super.key});

  @override
  State<DownStreamMediaKitExample> createState() => _DownStreamMediaKitExampleState();
}

class _DownStreamMediaKitExampleState extends State<DownStreamMediaKitExample> {
  final _urlController = TextEditingController(
    text: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'
  );
  
  // MediaKit Controllers
  late final Player _player;
  late final VideoController _videoController;
  
  List<DownloadInfo> _downloads = [];
  Timer? _refreshTimer;
  
  @override
  void initState() {
    super.initState();
    _initMediaKit();
    _initDownStream();
    
    // Poll for UI updates
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshList());
  }
  
  void _initMediaKit() {
    _player = Player();
    _videoController = VideoController(_player);
  }

  Future<void> _initDownStream() async {
    // 2. Initialize the Proxy Engine
    await DownStream.init(
      port: 8080, 
      userAgent: 'DownStreamPlayer/1.0',
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

    // 3. Get the Local Proxy URL
    // returns http://127.0.0.1:8080/stream?url=...
    final proxyUrl = DownStream.instance.cache(url);
    print("Playing from Proxy: $proxyUrl");

    // 4. Open in MediaKit
    await _player.open(Media(proxyUrl.toString()));
    await _player.play();
  }

  Future<void> _startBackgroundDownload(String url) async {
    // Start downloading without playing
    await DownStream.instance.startBackgroundDownload(url);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Background download started')),
      );
    }
  }

  Future<void> _exportFile(DownloadInfo item) async {
    if (!item.isComplete) return;

    final docsDir = Directory.systemTemp; 
    final targetPath = '${docsDir.path}/${item.fileName ?? "video.mp4"}';
    
    final success = await DownStream.instance.exportFile(item.originalUrl ?? "", targetPath);
    
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to $targetPath')),
      );
    }
  }

  Future<void> _clearAll() async {
    await _player.stop();
    await DownStream.instance.clearAllCache();
    await _refreshList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DownStream + MediaKit')),
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
          Container(
            height: 240,
            color: Colors.black,
            child: Video(controller: _videoController),
          ),
          
          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
               IconButton(
                 icon: const Icon(Icons.pause), 
                 onPressed: () => _player.pause()
               ),
               IconButton(
                 icon: const Icon(Icons.play_arrow), 
                 onPressed: () => _player.play()
               ),
            ],
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
                    // Resume playback
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
    _player.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }
}