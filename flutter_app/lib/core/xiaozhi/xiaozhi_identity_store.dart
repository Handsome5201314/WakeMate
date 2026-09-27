import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class XiaozhiIdentity {
  final String deviceId;
  final String clientId;

  const XiaozhiIdentity({required this.deviceId, required this.clientId});
}

class XiaozhiIdentityStore {
  static const _deviceIdKey = 'xiaozhi_device_id';
  static const _clientIdKey = 'xiaozhi_client_id';
  static const _uuid = Uuid();

  Future<XiaozhiIdentity> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);
    var clientId = prefs.getString(_clientIdKey);
    deviceId ??= _createDeviceId();
    clientId ??= _uuid.v4();
    await prefs.setString(_deviceIdKey, deviceId);
    await prefs.setString(_clientIdKey, clientId);
    return XiaozhiIdentity(deviceId: deviceId, clientId: clientId);
  }

  String _createDeviceId() {
    final bytes = List<int>.generate(6, (_) => Random.secure().nextInt(256));
    bytes[0] = (bytes[0] & 0xfe) | 0x02;
    return bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }
}
