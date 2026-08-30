import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

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
      title: 'Remote Pulse',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
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
  // رابط السيرفر السحابي المرفوع على Render (أو غيره)
  static const String serverDomain = "remote-pulse-server.onrender.com";
  static const String deviceId = "my_device_123";

  bool _isConnected = false;
  String _statusMessage = 'جاري الاتصال بالسيرفر السحابي...';
  WebSocket? _webSocket;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _connectToCloudServer();
    // إعادة محاولة الاتصال كل 5 ثوانٍ في حال الانقطاع
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected) {
        _connectToCloudServer();
      }
    });
  }

  Future<void> _connectToCloudServer() async {
    try {
      final wsUrl = 'wss://$serverDomain/ws/phone/$deviceId';
      _webSocket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 8));

      if (mounted) {
        setState(() {
          _isConnected = true;
          _statusMessage = 'متصل بالسيرفر بنجاح!\nجاهز لنقل البيانات عبر أي شبكة';
        });
      }

      _webSocket?.listen(
        (data) {
          // استقبال الأوامر والرسائل
        },
        onError: (e) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    if (mounted) {
      setState(() {
        _isConnected = false;
        _statusMessage = 'تم قطع الاتصال، جاري إعادة المحاولة...';
      });
    }
    _webSocket?.close();
    _webSocket = null;
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _webSocket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color backgroundColor = _isConnected ? Colors.green.shade900 : Colors.grey.shade900;
    final Color cardColor = _isConnected ? Colors.green.shade800 : Colors.grey.shade800;
    final Color iconColor = _isConnected ? Colors.greenAccent : Colors.orangeAccent;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Remote Pulse App', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        color: backgroundColor,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Container(
              padding: const EdgeInsets.all(24.0),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: _isConnected
                    ? [
                        BoxShadow(
                          color: Colors.greenAccent.withOpacity(0.5),
                          blurRadius: 20,
                          spreadRadius: 5,
                        )
                      ]
                    : [],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isConnected ? Icons.cloud_done : Icons.cloud_off,
                    size: 90,
                    color: iconColor,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 30),
                  ElevatedButton.icon(
                    onPressed: _connectToCloudServer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isConnected ? Colors.greenAccent : Colors.white,
                      foregroundColor: Colors.black,
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('إعادة الاتصال'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
