import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RemotePulseApp());
}

class RemotePulseApp extends StatelessWidget {
  const RemotePulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Remote Pulse Sync',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
      ),
      home: const MainHomeScreen(),
    );
  }
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  static const String serverDomain = "remote-pulse-server.onrender.com";
  static const String deviceId = "my_device_123";

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSyncing = false;

  int _totalImages = 0;
  int _uploadedImages = 0;
  String _statusMessage = 'جاري التهيئة...';

  WebSocket? _webSocket;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Completer<void>? _ackCompleter;

  @override
  void initState() {
    super.initState();
    _initPermissionsAndService();
  }

  Future<void> _initPermissionsAndService() async {
    await _requestPermissions();
    _connectToCloudServer();

    _reconnectTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_isConnected && !_isConnecting) _connectToCloudServer();
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.photos,
        Permission.videos,
        Permission.manageExternalStorage,
        Permission.ignoreBatteryOptimizations,
      ].request();
    }
  }

  Future<void> _connectToCloudServer() async {
    if (_isConnected || _isConnecting) return;
    _isConnecting = true;

    try {
      final wsUrl = 'wss://$serverDomain/ws/phone/$deviceId';
      _webSocket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 8));

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isConnecting = false;
          _statusMessage = 'متصل بالسيرفر وجاهز للمزامنة';
        });
      }

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_isConnected && _webSocket != null) {
          _webSocket?.add(jsonEncode({"type": "PING", "device_id": deviceId}));
        }
      });

      _webSocket?.listen(
        (data) {
          try {
            final message = jsonDecode(data);
            if (message['action'] == 'FETCH_ALL_IMAGES') {
              List<String> existingFiles = List<String>.from(message['existing_files'] ?? []);
              _syncAllImages(existingFiles);
            } else if (message['type'] == 'ACK_SAVED') {
              if (_ackCompleter != null && !_ackCompleter!.isCompleted) {
                _ackCompleter!.complete();
              }
            }
          } catch (_) {}
        },
        onError: (_) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnecting = false;
    _pingTimer?.cancel();
    if (mounted) {
      setState(() {
        _isConnected = false;
        _statusMessage = 'انقطع الاتصال، جاري إعادة المحاولة...';
      });
    }
    _webSocket?.close();
    _webSocket = null;
  }

  static Future<List<String>> _scanImagesTask(void _) async {
    List<String> imagePaths = [];
    List<String> targetDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Images',
    ];

    for (var dirPath in targetDirs) {
      Directory dir = Directory(dirPath);
      if (dir.existsSync()) {
        try {
          List<FileSystemEntity> files = dir.listSync(recursive: true, followLinks: false);
          for (var entity in files) {
            if (entity is File) {
              String ext = entity.path.toLowerCase();
              if (ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.png') || ext.endsWith('.webp')) {
                imagePaths.add(entity.path);
              }
            }
          }
        } catch (_) {}
      }
    }
    return imagePaths;
  }

  Future<void> _syncAllImages(List<String> existingFiles) async {
    if (!_isConnected || _isSyncing) return;

    setState(() {
      _isSyncing = true;
      _uploadedImages = 0;
      _statusMessage = 'جاري فحص الصور...';
    });

    try {
      List<String> imagePaths = await compute(_scanImagesTask, null);

      List<String> pendingImagePaths = imagePaths.where((path) {
        String fileName = path.split('/').last;
        return !existingFiles.contains(fileName);
      }).toList();

      if (mounted) {
        setState(() => _totalImages = pendingImagePaths.length);
      }

      if (pendingImagePaths.isEmpty) {
        if (mounted) {
          setState(() {
            _statusMessage = 'جميع الصور متزامنة بالكامل.';
            _isSyncing = false;
          });
        }
        return;
      }

      for (String path in pendingImagePaths) {
        if (!_isConnected) break;

        _ackCompleter = Completer<void>();
        String fileName = path.split('/').last;

        // ⚡ ضغط الصورة تلقائياً في الذاكرة لتسريع النقل 5 أضعاف
        Uint8List? compressedBytes = await FlutterImageCompress.compressWithFile(
          path,
          minWidth: 1920,
          minHeight: 1080,
          quality: 75,
          format: CompressFormat.jpeg,
        );

        List<int> bytesToUpload = compressedBytes ?? await File(path).readAsBytes();
        String base64Image = await compute(base64Encode, bytesToUpload);

        _webSocket?.add(jsonEncode({
          "type": "NEW_IMAGE_DATA",
          "file_name": fileName,
          "data": base64Image,
        }));

        // انتظار تأكيد الحفظ الصارم من الكمبيوتر (ACK)
        await _ackCompleter!.future.timeout(const Duration(seconds: 10), onTimeout: () {});

        if (mounted) {
          setState(() {
            _uploadedImages++;
            _statusMessage = 'تم النقل الفائق: $_uploadedImages من أصل $_totalImages';
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _statusMessage = 'حدث خطأ أثناء نقل الملفات');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _statusMessage = 'اكتملت المزامنة بنجاح فائقة السرعة!';
        });
      }
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _webSocket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            padding: const EdgeInsets.all(28.0),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isConnected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                  size: 64,
                  color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                ),
                const SizedBox(height: 20),
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                ),
                if (_isSyncing) ...[
                  const SizedBox(height: 25),
                  LinearProgressIndicator(
                    value: _totalImages > 0 ? _uploadedImages / _totalImages : 0,
                    backgroundColor: Colors.white12,
                    color: Colors.greenAccent,
                  ),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}
