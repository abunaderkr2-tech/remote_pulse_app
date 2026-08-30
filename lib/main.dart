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
  static const int udpPort = 8888; // البورت المخصص للبحث التلقائي
  static const int tcpPort = 8080; // بورت الاتصال الرئيسي

  bool _isConnected = false;
  String _statusMessage = 'جاري البحث عن السيرفر تلقائياً...';
  Socket? _socket;
  RawDatagramSocket? _udpSocket;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _startAutoDiscovery();
    // إعادة محاولة البحث كل 5 ثوانٍ في حال عدم الاتصال
    _searchTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected) {
        _sendBroadcastQuery();
      }
    });
  }

  // بدء الاستماع لردود السيرفر عبر UDP
  Future<void> _startAutoDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket?.broadcastEnabled = true;

      _udpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _udpSocket?.receive();
          if (dg != null) {
            String message = String.fromCharCodes(dg.data).trim();
            if (message == 'SERVER_HERE' && !_isConnected) {
              String serverIp = dg.address.address;
              _connectToServer(serverIp);
            }
          }
        }
      });

      _sendBroadcastQuery();
    } catch (e) {
      setState(() {
        _statusMessage = 'حدث خطأ أثناء البحث عن السيرفر';
      });
    }
  }

  // إرسال نداء في الشبكة البحثية
  void _sendBroadcastQuery() {
    if (_isConnected) return;
    try {
      List<int> data = 'DISCOVER_SERVER'.codeUnits;
      _udpSocket?.send(data, InternetAddress('255.255.255.255'), udpPort);
    } catch (e) {
      // إهمال الأخطاء أثناء التكرار
    }
  }

  // الاتصال المباشر بالسيرفر فور اكتشاف الـ IP
  Future<void> _connectToServer(String ip) async {
    try {
      _socket = await Socket.connect(ip, tcpPort, timeout: const Duration(seconds: 5));
      setState(() {
        _isConnected = true;
        _statusMessage = 'تم اكتشاف السيرفر والاتصال بنجاح!\nIP: $ip';
      });

      _socket?.listen(
        (data) {},
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
        _statusMessage = 'تم قطع الاتصال، جاري إعادة البحث تلقائياً...';
      });
    }
    _socket?.destroy();
    _socket = null;
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _udpSocket?.close();
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
                _isConnected ? Icons.check_circle : Icons.sync,
                size: 90,
                color: _isConnected ? Colors.green : Colors.orange,
              ),
              const SizedBox(height: 20),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: _sendBroadcastQuery,
                icon: const Icon(Icons.search),
                label: const Text('إعادة البحث عن السيرفر'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
