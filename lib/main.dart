import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'mqtt_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RemotePulseApp());
}

class RemotePulseApp extends StatelessWidget {
  const RemotePulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Pulse Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MqttService _mqttService = MqttService();
  bool _isConnected = false;
  String _statusMessage = 'جاري التحضير...';

  @override
  void initState() {
    super.initState();
    _startAppFlow();
  }

  Future<void> _startAppFlow() async {
    // 1. طلب الأذونات المطلوبة
    await [
      Permission.storage,
      Permission.notification,
      Permission.ignoreBatteryOptimizations,
    ].request();

    // 2. تشغيل خدمة الاتصال بـ MQTT
    setState(() => _statusMessage = 'جاري الاتصال بالسيرفر السحابي...');
    
    await _mqttService.initializeMqtt(
      onSyncRequested: (existingFiles) {
        setState(() {
          _statusMessage = 'تم استلام طلب مزامنة من اللابتوب!\nعدد الصور المحلية: ${existingFiles.length}';
        });
      },
    );

    setState(() {
      _isConnected = _mqttService.client.connectionStatus?.state == MqttConnectionState.connected;
      _statusMessage = _isConnected ? 'متصل وجاهز لنقل البيانات ⚡' : 'فشل الاتصال بالشبكة ❌';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote Pulse App'),
        backgroundColor: const Color(0xFF1E293B),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isConnected ? Icons.check_circle_rounded : Icons.sync_problem_rounded,
                size: 80,
                color: _isConnected ? const Color(0xFF10B981) : const Color(0xFFEF4444),
              ),
              const SizedBox(height: 24),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _startAppFlow,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة الاتصال'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF38BDF8),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
