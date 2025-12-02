import 'package:flutter/material.dart';
import 'package:genesmanproxy/genesmanproxy.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DownStream Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'DownStream Demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool _isInitialized = false;
  final TextEditingController _urlController = TextEditingController();
  String? _proxyUrl;
  double _progress = 0.0;
  List<DownloadInfo> _downloads = [];
  FileStat? _fileStat;

  @override
  void initState() {
    super.initState();
    _initDownStream();
  }

  Future<void> _initDownStream() async {
    try {
      await DownStream.init(
        port: 8080,
        userAgent: 'DownStreamExample/1.0',
      );
      setState(() {
        _isInitialized = true;
      });
      _loadDownloads();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize: $e')),
        );
      }
    }
  }

  Future<void> _loadDownloads() async {
    if (!_isInitialized) return;
    
    try {
      final downloads = await DownStream.instance.getAllDownloads();
      setState(() {
        _downloads = downloads;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load downloads: $e')),
        );
      }
    }
  }

  void _startDownload() {
    if (!_isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('DownStream not initialized')),
      );
      return;
    }

    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a URL')),
      );
      return;
    }

    try {
      // Get proxy URL
      final proxyUrl = DownStream.instance.cache(url);
      
      // Listen to file stats
      DownStream.instance.getFileStats(url)?.listen((stat) {
        setState(() {
          _fileStat = stat;
        });
      });
      
      setState(() {
        _proxyUrl = proxyUrl.toString();
      });

      // Start tracking progress
      _trackProgress(url);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Proxy URL: $proxyUrl')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  void _trackProgress(String url) {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !_isInitialized) return;
      
      final progress = DownStream.instance.getProgress(url);
      setState(() {
        _progress = progress;
      });
      
      if (progress < 100.0) {
        _trackProgress(url);
      } else {
        _loadDownloads();
      }
    });
  }

  Future<void> _cancelDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    try {
      await DownStream.instance.cancelDownload(url);
      setState(() {
        _progress = 0.0;
        _proxyUrl = null;
        _fileStat = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download cancelled')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error cancelling: $e')),
      );
    }
  }

  Future<void> _removeCache(String fileId) async {
    try {
      await DownStream.instance.removeCacheById(fileId);
      _loadDownloads();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache removed')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error removing cache: $e')),
      );
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_isInitialized)
              const Center(
                child: CircularProgressIndicator(),
              )
            else ...[
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Enter URL',
                  hintText: 'https://example.com/video.mp4',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _startDownload,
                      child: const Text('Start Download'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _cancelDownload,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_proxyUrl != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Proxy URL:',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _proxyUrl!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        if (_fileStat != null) ...[
                          const SizedBox(height: 16),
                          Text('File: ${_fileStat!.fileName ?? "Unknown"}'),
                          Text('Size: ${_formatBytes(_fileStat!.totalSize ?? 0)}'),
                          Text('Type: ${_fileStat!.mimeType ?? "Unknown"}'),
                        ],
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: _progress / 100,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Progress: ${_progress.toStringAsFixed(1)}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Downloads',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _downloads.isEmpty
                    ? const Center(child: Text('No downloads yet'))
                    : ListView.builder(
                        itemCount: _downloads.length,
                        itemBuilder: (context, index) {
                          final download = _downloads[index];
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                download.isComplete
                                    ? Icons.check_circle
                                    : Icons.download,
                                color: download.isComplete
                                    ? Colors.green
                                    : Colors.blue,
                              ),
                              title: Text(
                                download.id.substring(0, 16),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: Text(
                                '${_formatBytes(download.totalSize)} - ${download.progress.toStringAsFixed(1)}%',
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => _removeCache(download.id),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
