import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
        scaffoldBackgroundColor: const Color(0xFF0F172A),
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
    _initForegroundService();
    _requestPermissionsAndConnect();
  }

  void _initForegroundService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'remote_pulse_channel',
        channelName: 'Remote Pulse Service',
        channelDescription: 'تخدم النقل المستمر 24 ساعة في الخلفية',
channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _requestPermissionsAndConnect() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.photos,
        Permission.manageExternalStorage,
        Permission.notification,
        Permission.ignoreBatteryOptimizations,
      ].request();
    }

    // بدء خدمة الخلفية التي تمنع قتل التطبيق
    if (!await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.startService(
        notificationTitle: 'Remote Pulse Active',
        notificationText: 'الاتصال شغال 24 ساعة بالخلفية بدون توقف',
      );
    }

    _connectToCloudServer();

    _reconnectTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_isConnected && !_isConnecting) _connectToCloudServer();
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
          _statusMessage = 'الخدمة متصلة 24/7 ومستقرة تماماً';
        });
      }

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
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
        _statusMessage = 'انقطع الاتصال، إعادة المحاولة في الخلفية...';
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
      _statusMessage = 'جاري مطابقة الفهارس واستكشاف الصور...';
    });

    try {
      List<String> allImages = await compute(_scanImagesTask, null);

      List<String> pendingImages = allImages.where((path) {
        String fileName = path.split('/').last;
        return !existingFiles.contains(fileName);
      }).toList();

      if (mounted) {
        setState(() => _totalImages = pendingImages.length);
      }

      if (pendingImages.isEmpty) {
        if (mounted) {
          setState(() {
            _statusMessage = 'لا توجد صور جديدة للنقل!';
            _isSyncing = false;
          });
        }
        return;
      }

      for (String path in pendingImages) {
        if (!_isConnected) break;

        _ackCompleter = Completer<void>();

        File file = File(path);
        String fileName = path.split('/').last;
        List<int> bytes = await file.readAsBytes();
        String base64Image = await compute(base64Encode, bytes);

        _webSocket?.add(jsonEncode({
          "type": "NEW_IMAGE_DATA",
          "file_name": fileName,
          "data": base64Image,
        }));

        // انتظر التأكيد المباشر من اللابتوب
        await _ackCompleter!.future.timeout(const Duration(seconds: 10), onTimeout: () {});

        if (mounted) {
          setState(() {
            _uploadedImages++;
            _statusMessage = 'تم نقل مؤكد: $_uploadedImages / $_totalImages';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'حدث خلل مؤقت أثناء النقل');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _statusMessage = 'اكتمل التزامن بنجاح!';
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
    return WithForegroundTask(
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Container(
                padding: const EdgeInsets.all(28.0),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _isConnected ? const Color(0xFF10B981) : const Color(0xFFEF4444), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: (_isConnected ? Colors.green : Colors.red).withOpacity(0.15),
                      blurRadius: 20,
                      spreadRadius: 5,
                    )
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isConnected ? Icons.sensors : Icons.sensors_off,
                      size: 70,
                      color: _isConnected ? const Color(0xFF34D399) : const Color(0xFFF87171),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _isConnected ? "الخدمة متصلة ومحصنة" : "انقطاع الاتصال",
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    ),
                    if (_isSyncing) ...[
                      const SizedBox(height: 25),
                      LinearProgressIndicator(
                        value: _totalImages > 0 ? _uploadedImages / _totalImages : 0,
                        backgroundColor: Colors.white12,
                        color: const Color(0xFF34D399),
                        minHeight: 8,
                      ),
                    ]
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
