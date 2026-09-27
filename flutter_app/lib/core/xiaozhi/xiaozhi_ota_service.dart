import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'xiaozhi_identity_store.dart';
import 'xiaozhi_models.dart';

const String kXiaozhiOtaUrl = String.fromEnvironment(
  'XIAOZHI_OTA_URL',
  defaultValue: 'https://api.tenclass.net/xiaozhi/ota/',
);

class XiaozhiOtaException implements Exception {
  final String message;
  final int? statusCode;
  const XiaozhiOtaException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

class XiaozhiOtaService {
  final http.Client _client;
  final XiaozhiIdentityStore _identityStore;

  XiaozhiOtaService({http.Client? client, XiaozhiIdentityStore? identityStore})
      : _client = client ?? http.Client(),
        _identityStore = identityStore ?? XiaozhiIdentityStore();

  Future<XiaozhiOtaConfig> _config() async {
    final identity = await _identityStore.loadOrCreate();
    return XiaozhiOtaConfig(
      otaUrl: Uri.parse(kXiaozhiOtaUrl),
      deviceId: identity.deviceId,
      clientId: identity.clientId,
    );
  }

  Future<XiaozhiOtaResult> checkVersion() async {
    final config = await _config();
    final response = await _client.post(
      config.otaUrl,
      headers: {
        'Activation-Version': config.activationVersion.toString(),
        'Device-Id': config.deviceId,
        'Client-Id': config.clientId,
        'User-Agent': config.userAgent,
        'Accept-Language': config.language,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(config.toJson()),
    );
    if (response.statusCode != 200) {
      throw XiaozhiOtaException(
        '小智 OTA 请求失败：${response.body.isEmpty ? '服务器未返回错误信息' : response.body}',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const XiaozhiOtaException('小智 OTA 返回格式无效');
    }
    final result = XiaozhiOtaResult.fromJson(decoded);
    final prefs = await SharedPreferences.getInstance();
    if (result.websocketUrl != null) {
      await prefs.setString('xiaozhi_ws_url', result.websocketUrl.toString());
    }
    if (result.token != null && result.token!.isNotEmpty) {
      await prefs.setString('xiaozhi_token', result.token!);
    }
    await prefs.setInt('xiaozhi_protocol_version', result.protocolVersion);
    return result;
  }

  Future<bool> activate({required XiaozhiOtaResult ota}) async {
    final config = await _config();
    final activateUrl = config.otaUrl.path.endsWith('/')
        ? config.otaUrl.resolve('activate')
        : config.otaUrl.resolve('${config.otaUrl.pathSegments.last}/activate');
    final response = await _client.post(
      activateUrl,
      headers: {
        'Activation-Version': config.activationVersion.toString(),
        'Device-Id': config.deviceId,
        'Client-Id': config.clientId,
        'User-Agent': config.userAgent,
        'Accept-Language': config.language,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{}),
    );
    if (response.statusCode == 202) return false;
    if (response.statusCode != 200) {
      throw XiaozhiOtaException(
        '小智激活请求失败：${response.body.isEmpty ? '服务器未返回错误信息' : response.body}',
        statusCode: response.statusCode,
      );
    }
    return true;
  }

  Future<XiaozhiOtaResult> waitForActivation({
    required XiaozhiOtaResult initial,
    int? maxAttempts,
    Duration retryDelay = const Duration(seconds: 3),
  }) async {
    if (!initial.requiresActivation) return initial;
    final timeout = initial.activationTimeout <= Duration.zero
        ? const Duration(seconds: 30)
        : initial.activationTimeout;
    final deadline = DateTime.now().add(timeout);
    var attempts = 0;
    while (DateTime.now().isBefore(deadline) &&
        (maxAttempts == null || attempts < maxAttempts)) {
      attempts++;
      final activated = await activate(ota: initial);
      if (activated) return checkVersion();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
          remaining < retryDelay ? remaining : retryDelay);
    }
    throw const XiaozhiOtaException('等待小智设备激活超时，请确认已在 xiaozhi.me 输入 6 位验证码');
  }

  void dispose() => _client.close();
}
