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
  // عنوان السيرفر المحلي أو الثابت (قم بتعديل IP والسيرفر حسب الإعدادات الخاصة بك)
  final String _serverIp = '192.168.1.100'; 
  final int _serverPort = 8080;

  bool _isConnected = false;
  String _statusMessage = 'جاري محاولة الاتصال بالسيرفر...';
  Timer? _pingTimer;
  Socket? _socket;

  @override
  void initState() {
    super.initState();
    _connectToServer();
    // إرسال نبضة استعادة اتصال كل 10 ثوانٍ لضمان بقاء التطبيق متصلاً 24 ساعة
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!_isConnected) {
        _connectToServer();
      }
    });
  }

  Future<void> _connectToServer() async {
    try {
      _socket = await Socket.connect(_serverIp, _serverPort, timeout: const Duration(seconds: 5));
      setState(() {
        _isConnected = true;
        _statusMessage = 'متصل بالسيرفر بنجاح';
      });

      _socket?.listen(
        (data) {
          // استقبال الأوامر من السيرفر
        },
        onError: (error) {
          _handleDisconnect();
        },
        onDone: () {
          _handleDisconnect();
        },
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    if (mounted) {
      setState(() {
        _isConnected = false;
        _statusMessage = 'تعذر الاتصال، يتم إعادة المحاولة...';
      });
    }
    _socket?.destroy();
    _socket = null;
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _socket?.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote Pulse App'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isConnected ? Icons.check_circle : Icons.error_outline,
                size: 90,
                color: _isConnected ? Colors.green : Colors.red,
              ),
              const SizedBox(height: 20),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: _connectToServer,
                icon: const Icon(Icons.refresh),
                label: const Text('تحديث الاتصال'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
