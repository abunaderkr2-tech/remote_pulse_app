import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttService {
  late MqttServerClient client;
  
  final String broker = 'test.mosquitto.org';
  final int port = 1883;
  final String clientIdentifier = 'Mobile_App_Client';

  final String topicMobileStatus = 'remotepulse/device123/mobile/status';
  final String topicCommands = 'remotepulse/device123/commands';
  final String topicImageEvents = 'remotepulse/device123/images';

  Future<void> initializeMqtt({
    required Function(List<String> existingFiles) onSyncRequested,
  }) async {
    client = MqttServerClient(broker, clientIdentifier);
    client.port = port;
    client.keepAlivePeriod = 15;
    client.logging(on: false);

    // ضبط ميزة LWT (Last Will and Testament)
    // إذا انقطع الاتصال أو أُغلق التطبيق، سيعلم الوسيط اللابتوب فوراً بأن الجوال offline
    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .startClean()
        .withWillTopic(topicMobileStatus)
        .withWillMessage('offline')
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain();

    client.connectionMessage = connMess;

    try {
      await client.connect();
    } catch (e) {
      client.disconnect();
      return;
    }

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      // إعلان حالة الجوال أونلاين فور الاتصال
      final builder = MqttClientPayloadBuilder();
      builder.addString('online');
      client.publishMessage(topicMobileStatus, MqttQos.atLeastOnce, builder.payload!, retain: true);

      // الاشتراك في استلام الأوامر من اللابتوب
      client.subscribe(topicCommands, MqttQos.atLeastOnce);

      // استماع للرسائل القادمة
      client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
        final String pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        if (c[0].topic == topicCommands) {
          final data = jsonDecode(pt);
          if (data['action'] == 'SYNC_REQUEST') {
            List<String> existingFiles = List<String>.from(data['existing_files'] ?? []);
            onSyncRequested(existingFiles);
          }
        }
      });
    }
  }

  // إرسال رابط الصورة للابتوب فور رفعها أو توفرها
  void notifyNewImage(String fileName, String downloadUrl) {
    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      final payload = jsonEncode({
        'file_name': fileName,
        'url': downloadUrl,
      });

      final builder = MqttClientPayloadBuilder();
      builder.addString(payload);
      client.publishMessage(topicImageEvents, MqttQos.atLeastOnce, builder.payload!);
    }
  }
}
