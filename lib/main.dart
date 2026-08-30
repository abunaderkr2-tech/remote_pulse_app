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
  static const int udpPort = 8888;
  static const int tcpPort = 8080;

  bool _isConnected = false;
  String _statusMessage = 'جاري البحث عن السيرفر تلقائياً...';
  Socket? _socket;
  RawDatagramSocket? _udpSocket;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _startAutoDiscovery();
    _searchTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected) {
        _sendBroadcastQuery();
      }
    });
  }

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

  void _sendBroadcastQuery() {
    if (_isConnected) return;
    try {
      List<int> data = 'DISCOVER_SERVER'.codeUnits;
      _udpSocket?.send(data, InternetAddress('255.255.255.255'), udpPort);
    } catch (e) {
      // إهمال الأخطاء أثناء التكرار
    }
  }

  Future<void> _connectToServer(String ip) async {
    try {
      _socket = await Socket.connect(ip, tcpPort, timeout: const Duration(seconds: 5));
      setState(() {
        _isConnected = true;
        _statusMessage = 'متصل بالسيرفر بنجاح!\nIP: $ip';
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
    // تحديد الألوان بناءً على حالة الاتصال
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
        duration: const Duration(milliseconds: 500), // تأثير انسيابي عند تغيير اللون
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
                    _isConnected ? Icons.wifi : Icons.wifi_off,
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
                    onPressed: _sendBroadcastQuery,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isConnected ? Colors.greenAccent : Colors.white,
                      foregroundColor: Colors.black,
                    ),
                    icon: const Icon(Icons.search),
                    label: const Text('إعادة البحث عن السيرفر'),
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
