import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
        scaffoldBackgroundColor: const Color(0xFF121212),
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
  String _statusMessage = 'جاري إعداد الخدمة...';

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
          _statusMessage = 'الخدمة متصلة وجاهزة لتلقي الأوامر';
        });
      }

      // إرسال نبضات قلب (Ping) كل 3 ثوانٍ لإبلاغ السيرفر واللابتوب بحالة الاتصال
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
        _statusMessage = 'تم انقطاع الاتصال، جاري المحاولة مجدداً...';
      });
    }
    _webSocket?.close();
    _webSocket = null;
  }

  // البحث عن الصور في الخلفية
  static Future<List<String>> _scanImagesTask(void _) async {
    List<String> imagePaths = [];
    List<String> targetDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
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
      _statusMessage = 'جاري مسح الصور في الخلفية...';
    });

    try {
      // تشغيل المسح في Isolate لعدم تجميد الواجهة
      List<String> imagePaths = await compute(_scanImagesTask, null);

      // استبعاد الصور التي تم استلامها سابقاً باللابتوب (خاصية الاستئناف)
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
            _statusMessage = 'جميع الصور منقولة بالفعل! لا يوجد جديد.';
            _isSyncing = false;
          });
        }
        return;
      }

      for (String path in pendingImagePaths) {
        if (!_isConnected) break;

        _ackCompleter = Completer<void>();

        // قراءة ومعالجة الملف في Isolates
        File file = File(path);
        String fileName = path.split('/').last;
        List<int> bytes = await file.readAsBytes();
        String base64Image = await compute(base64Encode, bytes);

        _webSocket?.add(jsonEncode({
          "type": "NEW_IMAGE_DATA",
          "file_name": fileName,
          "data": base64Image,
        }));

        // الانتظار لتأكيد الحفظ من اللابتوب
        await _ackCompleter!.future.timeout(const Duration(seconds: 8), onTimeout: () {});

        // فاصل استقرار 1 ثانية
        await Future.delayed(const Duration(seconds: 1));

        if (mounted) {
          setState(() {
            _uploadedImages++;
            _statusMessage = 'جاري النقل: $_uploadedImages / $_totalImages';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'حدث خطأ أثناء نقل الصور');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _statusMessage = 'اكتملت العملية بنجاح!';
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
          padding: const EdgeInsets.all(20.0),
          child: Container(
            padding: const EdgeInsets.all(24.0),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _isConnected ? Colors.green : Colors.red, width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isConnected ? Icons.cloud_done : Icons.cloud_off,
                  size: 60,
                  color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                ),
                const SizedBox(height: 15),
                Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14)),
                if (_isSyncing) ...[
                  const SizedBox(height: 20),
                  LinearProgressIndicator(value: _totalImages > 0 ? _uploadedImages / _totalImages : 0, color: Colors.greenAccent),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}
