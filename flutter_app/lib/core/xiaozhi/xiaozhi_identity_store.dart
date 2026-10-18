import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class XiaozhiIdentity {
  final String deviceId;
  final String clientId;

  const XiaozhiIdentity({required this.deviceId, required this.clientId});
}

class XiaozhiIdentityStore {
  final String userId;
  static const _uuid = Uuid();
  static final _pendingLoads = <String, Future<XiaozhiIdentity>>{};
  Future<XiaozhiIdentity>? _loading;

  XiaozhiIdentityStore({required this.userId}) {
    if (userId.trim().isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'WakeMate account required');
    }
  }

  String get _deviceIdKey => 'xiaozhi_${Uri.encodeComponent(userId)}_device_id';
  String get _clientIdKey => 'xiaozhi_${Uri.encodeComponent(userId)}_client_id';

  Future<XiaozhiIdentity> loadOrCreate() =>
      _loading ??= _pendingLoads.putIfAbsent(
        userId,
        () => _loadOrCreate().whenComplete(() {
          _pendingLoads.remove(userId);
        }),
      );

  Future<XiaozhiIdentity> _loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    // An older installation's global identity has no trustworthy owner. Each
    // signed-in account activates its own device instead of inheriting it.
    for (final key in const [
      'xiaozhi_device_id',
      'xiaozhi_client_id',
      'xiaozhi_token',
      'xiaozhi_ws_url',
      'xiaozhi_protocol_version',
    ]) {
      await prefs.remove(key);
    }
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
