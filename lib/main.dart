import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

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
  bool _isUploading = false;
  String _statusMessage = 'جاري الاتصال بالسيرفر...';

  WebSocket? _webSocket;
  Timer? _reconnectTimer;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _connectToCloudServer();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToCloudServer();
      }
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
          _statusMessage = 'متصل بالسيرفر بنجاح\nجاهز لإرسال واستقبال الصور';
        });
      }

      _webSocket?.listen(
        (data) {
          try {
            final message = jsonDecode(data);
            // الاستماع لأمر سحب الصورة من اللابتوب
            if (message['action'] == 'FETCH_LATEST_IMAGE') {
              _pickAndUploadImage();
            }
          } catch (e) {
            // إهمال الرسائل غير المتوافقة
          }
        },
        onError: (e) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
        cancelOnError: true,
      );
    } catch (e) {
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

  // رفع الصورة المحددة إلى السيرفر
  Future<void> _pickAndUploadImage() async {
    if (!_isConnected || _isUploading) return;

    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    setState(() {
      _isUploading = true;
    });

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://$serverDomain/upload/$deviceId'),
      );
      request.files.add(await http.MultipartFile.fromPath('file', image.path));

      final response = await request.send();
      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم رفع الصورة وإرسالها بنجاح!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('فشل رفع الصورة'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
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
        title: const Text('Remote Pulse', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
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
                    ? [BoxShadow(color: Colors.greenAccent.withOpacity(0.4), blurRadius: 20, spreadRadius: 3)]
                    : [],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isConnected ? Icons.cloud_done : Icons.cloud_off,
                    size: 80,
                    color: _isConnected ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                  const SizedBox(height: 15),
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 25),
                  if (_isUploading)
                    const CircularProgressIndicator(color: Colors.greenAccent)
                  else
                    ElevatedButton.icon(
                      onPressed: _isConnected ? _pickAndUploadImage : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.greenAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('رفع وإرسال صورة', style: TextStyle(fontWeight: FontWeight.bold)),
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
