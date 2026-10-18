// 硬件设备页：真实设备列表与一次性绑定码认领
// 醒伴 WakeMate Flutter APP

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/rest_client.dart';
import '../../core/theme/wakemate_theme.dart';
import '../../shared/providers/auth_provider.dart';

class DevicePage extends ConsumerStatefulWidget {
  const DevicePage({super.key});

  @override
  ConsumerState<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends ConsumerState<DevicePage> {
  final _deviceSnController = TextEditingController();
  final _claimCodeController = TextEditingController();
  List<Map<String, dynamic>> _devices = const [];
  bool _loading = true;
  bool _claiming = false;
  String? _loadError;
  String? _claimError;
  int _loadGeneration = 0;
  int _sessionGeneration = 0;
  String? _accountId;
  CancelToken? _claimCancelToken;
  late final ProviderSubscription<AsyncValue<AuthState>> _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = ref.listenManual(authProvider, (_, next) {
      final account = next is AsyncData<AuthState> ? next.value : null;
      final accountId =
          account?.isAuthenticated == true ? account?.userId : null;
      if (accountId == _accountId) return;
      _sessionGeneration++;
      _loadGeneration++;
      _claimCancelToken?.cancel('WakeMate account changed');
      _claimCancelToken = null;
      _accountId = accountId;
      _deviceSnController.clear();
      _claimCodeController.clear();
      setState(() {
        _devices = const [];
        _claiming = false;
        _loading = false;
        _loadError = null;
        _claimError = null;
      });
      if (accountId != null) _loadDevices();
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _authSubscription.close();
    _claimCancelToken?.cancel('Device page disposed');
    _deviceSnController.dispose();
    _claimCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final generation = ++_loadGeneration;
    final session = _sessionGeneration;
    if (mounted) setState(() => _loading = true);
    try {
      final result = await ref.read(apiProvider).getDevices();
      if (!_isCurrentSession(accountId, session) ||
          generation != _loadGeneration) {
        return;
      }
      if (result.any((item) => item is! Map<String, dynamic>)) {
        throw const FormatException('设备列表响应格式不正确');
      }
      final devices =
          result.cast<Map<String, dynamic>>().toList(growable: false);
      setState(() {
        _devices = devices;
        _loading = false;
        _loadError = null;
      });
    } catch (_) {
      if (!_isCurrentSession(accountId, session) ||
          generation != _loadGeneration) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = '设备列表加载失败，请检查网络后重试';
      });
    }
  }

  Future<void> _claimDevice() async {
    if (_claiming) return;
    final accountId = _accountId;
    if (accountId == null) return;
    final session = _sessionGeneration;
    final deviceSn = _deviceSnController.text.trim();
    final claimCode = _claimCodeController.text.trim();
    if (deviceSn.isEmpty || claimCode.isEmpty) {
      setState(() => _claimError = '请填写设备序列号和绑定码');
      return;
    }
    if (deviceSn.length > 64 ||
        claimCode.length < 8 ||
        claimCode.length > 128) {
      setState(() => _claimError = '序列号最多 64 位，绑定码应为 8–128 位。');
      return;
    }
    FocusScope.of(context).unfocus();
    final cancelToken = CancelToken();
    _claimCancelToken = cancelToken;
    setState(() {
      _claiming = true;
      _claimError = null;
    });
    try {
      await ref.read(apiProvider).bindDevice(
            deviceSn: deviceSn,
            claimCode: claimCode,
            cancelToken: cancelToken,
          );
      if (!_isCurrentSession(accountId, session)) return;
      final messenger = ScaffoldMessenger.of(context);
      _deviceSnController.clear();
      _claimCodeController.clear();
      _claimCancelToken = null;
      setState(() => _claiming = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('设备已绑定到当前醒伴账号')),
      );
      await _loadDevices();
    } catch (error) {
      if (!_isCurrentSession(accountId, session)) return;
      setState(() {
        _claimCancelToken = null;
        _claiming = false;
        _claimError = _claimErrorMessage(error);
      });
    }
  }

  bool _isCurrentSession(String accountId, int generation) =>
      mounted && _accountId == accountId && _sessionGeneration == generation;

  String _claimErrorMessage(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401) return '登录已过期，请重新登录后再绑定设备。';
      if (status == 403) return '绑定码无效、已使用或已过期，请向管理员重新获取。';
      if (status == 422) return '设备序列号或绑定码格式不正确，请检查后重试。';
      if (status != null && status >= 500) return '服务暂时不可用，请稍后重试。';
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return '网络连接失败，请检查网络后重试。';
      }
    }
    if (error is StateError) return error.message;
    return '设备绑定失败，请稍后重试。';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_claiming,
      child: Scaffold(
        backgroundColor: WMColors.bgPage,
        appBar: AppBar(title: const Text('硬件设备')),
        body: RefreshIndicator(
          onRefresh: () async {
            if (!_claiming) await _loadDevices();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              WMSpacing.md,
              WMSpacing.md,
              WMSpacing.md,
              WMSpacing.xl,
            ),
            children: [
              if (_accountId == null)
                const Padding(
                  padding: EdgeInsets.all(WMSpacing.lg),
                  child: Text('请先登录醒伴账号，再查看或绑定设备。'),
                )
              else ...[
                _buildClaimCard(),
                const SizedBox(height: WMSpacing.md),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(WMSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_loadError != null)
                  _buildLoadError()
                else
                  _buildDeviceList(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClaimCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('绑定醒伴设备',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              '从管理员处获取设备序列号和 24 小时一次性绑定码。Wi-Fi 开发板无需蓝牙配对；小智激活与醒伴设备认领分别完成。',
              style: TextStyle(fontSize: 13, color: WMColors.ink500),
            ),
            const SizedBox(height: WMSpacing.md),
            TextField(
              key: const ValueKey('device-sn-field'),
              controller: _deviceSnController,
              enabled: !_claiming,
              textInputAction: TextInputAction.next,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: '设备序列号',
                hintText: '例如 WM-PILL-001',
                counterText: '',
              ),
            ),
            const SizedBox(height: WMSpacing.sm),
            TextField(
              key: const ValueKey('claim-code-field'),
              controller: _claimCodeController,
              enabled: !_claiming,
              maxLength: 128,
              obscureText: true,
              onSubmitted: (_) => _claimDevice(),
              decoration: const InputDecoration(
                labelText: '一次性绑定码',
                hintText: '24 小时内有效',
                counterText: '',
              ),
            ),
            if (_claimError != null) ...[
              const SizedBox(height: WMSpacing.sm),
              Text(_claimError!,
                  key: const ValueKey('claim-error'),
                  style: const TextStyle(color: WMColors.danger, fontSize: 13)),
            ],
            const SizedBox(height: WMSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const ValueKey('claim-device-button'),
                onPressed: _claiming ? null : _claimDevice,
                icon: _claiming
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: Text(_claiming ? '绑定中…' : '绑定设备'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadError() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.md),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_outlined, color: WMColors.danger),
            const SizedBox(width: WMSpacing.sm),
            const Expanded(
                child: Text('设备列表加载失败，请检查网络后重试',
                    style: TextStyle(color: WMColors.danger))),
            TextButton(onPressed: _loadDevices, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList() {
    if (_devices.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(WMSpacing.lg),
          child: Column(
            children: const [
              Icon(Icons.devices_other_outlined,
                  size: 40, color: WMColors.ink500),
              SizedBox(height: WMSpacing.sm),
              Text('当前账号还没有绑定醒伴设备',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: WMSpacing.xs),
              Text('绑定后，设备心跳和用药计划会显示在这里。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: WMColors.ink500)),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('已绑定设备（${_devices.length}）',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: WMSpacing.sm),
        ..._devices.asMap().entries.map(
              (entry) => Padding(
                padding: EdgeInsets.only(
                    bottom:
                        entry.key == _devices.length - 1 ? 0 : WMSpacing.sm),
                child: _buildDeviceCard(entry.value),
              ),
            ),
      ],
    );
  }

  Widget _buildDeviceCard(Map<String, dynamic> device) {
    final state = device['state'] is Map
        ? Map<String, dynamic>.from(device['state'] as Map)
        : const <String, dynamic>{};
    final status = _statusLabel(device, state);
    final online = status == '在线';
    final type = _deviceTypeLabel(device['device_type']);
    final firmware = _stringOrNull(device['firmware_ver']) ?? '未知';
    final battery = state['battery'] is num ? '${state['battery']}%' : '未知';
    final lastSync = _formatDate(device['last_sync_at']);
    return Card(
      key: ValueKey('device-card-${device['id'] ?? device['device_sn']}'),
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_other_outlined,
                    color: WMColors.brandPrimary),
                const SizedBox(width: WMSpacing.sm),
                Expanded(
                  child: Text(type,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                _statusBadge(status, online),
              ],
            ),
            const Divider(height: WMSpacing.lg),
            _detailRow('设备序列号', _stringOrNull(device['device_sn']) ?? '未知',
                mono: true),
            _detailRow('固件版本', firmware),
            _detailRow('电量', battery),
            _detailRow('最近同步', lastSync),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(String status, bool online) {
    final color = online ? WMColors.brandSecondary : WMColors.ink500;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
          color: online ? WMColors.brandSecondarySoft : WMColors.ink200,
          borderRadius: WMRadius.pill),
      child: Text(status,
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w500)),
    );
  }

  Widget _detailRow(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 88,
              child:
                  Text(label, style: const TextStyle(color: WMColors.ink500))),
          Expanded(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontFamily: mono ? 'monospace' : null,
                      color: WMColors.ink900))),
        ],
      ),
    );
  }

  String _statusLabel(Map<String, dynamic> device, Map<String, dynamic> state) {
    final hasHeartbeat =
        device['last_sync_at'] != null || state['last_heartbeat'] != null;
    final raw = state['status']?.toString().toLowerCase();
    if (!hasHeartbeat) return '尚未上报';
    if (raw == 'online') return '在线';
    return '离线';
  }

  String _deviceTypeLabel(Object? value) {
    switch (value?.toString()) {
      case 'pillbox':
        return '醒伴智能药盒';
      case 'clasp_bead':
        return '醒伴药珠';
      default:
        return value?.toString().isNotEmpty == true ? value.toString() : '醒伴设备';
    }
  }

  String? _stringOrNull(Object? value) =>
      value == null || value.toString().trim().isEmpty
          ? null
          : value.toString();

  String _formatDate(Object? value) {
    final raw = _stringOrNull(value);
    if (raw == null) return '尚未同步';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
