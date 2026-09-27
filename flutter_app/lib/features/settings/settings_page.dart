// lib/features/settings/settings_page.dart（更新版）
// 新增硬件商城入口
// 醒伴 WakeMate Flutter APP · 醒时科技 Wakeshift

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _familyPush = true;
  TimeOfDay _quietStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _quietEnd = const TimeOfDay(hour: 7, minute: 0);
  bool _deviceLoading = true;
  bool _deviceConnected = false;
  int? _deviceBattery;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadDeviceSummary();
  }

  Future<void> _loadDeviceSummary() async {
    try {
      final devices = await ref.read(apiProvider).getDevices();
      if (!mounted) return;
      Map<String, dynamic>? device;
      for (final item in devices) {
        if (item is Map<String, dynamic>) {
          device = item;
          break;
        }
      }
      final rawState = device?['state'];
      final state =
          rawState is Map ? Map<String, dynamic>.from(rawState) : device;
      setState(() {
        _deviceLoading = false;
        _deviceConnected = _isDeviceOnline(state);
        _deviceBattery = (state?['battery'] as num?)?.toInt();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deviceLoading = false;
        _deviceConnected = false;
        _deviceBattery = null;
      });
    }
  }

  Future<void> _loadSettings() async {
    try {
      final data = await ref.read(apiProvider).getSettings();
      if (!mounted) return;
      setState(() {
        _familyPush = data['family_push_enabled'] as bool? ?? true;
        _quietStart = _parseTime(data['quiet_start'] as String? ?? '22:00');
        _quietEnd = _parseTime(data['quiet_end'] as String? ?? '07:00');
      });
    } catch (_) {
      if (mounted) _snack('设置加载失败，请检查网络后重试');
    }
  }

  Future<void> _saveSetting(String key, dynamic value,
      {VoidCallback? onFailure}) async {
    final payload = <String, dynamic>{
      if (key == 'wm_family_push') 'family_push_enabled': value,
      if (key == 'wm_quiet_start') 'quiet_start': value,
      if (key == 'wm_quiet_end') 'quiet_end': value,
    };
    if (payload.isEmpty) return;
    try {
      await ref.read(apiProvider).updateSettings(payload);
      final p = await SharedPreferences.getInstance();
      if (value is bool) await p.setBool(key, value);
      if (value is String) await p.setString(key, value);
      _snack('设置已保存');
    } catch (_) {
      onFailure?.call();
      if (mounted) _snack('设置保存失败，请检查网络后重试');
    }
  }

  bool _isDeviceOnline(Map<String, dynamic>? state) {
    if (state == null) return false;
    if (state['status']?.toString() == 'online') return true;
    final rawHeartbeat = state['last_heartbeat']?.toString();
    final heartbeat =
        rawHeartbeat == null ? null : DateTime.tryParse(rawHeartbeat);
    if (heartbeat == null) return false;
    return DateTime.now().toUtc().difference(heartbeat.toUtc()).inSeconds <=
        120;
  }

  TimeOfDay _parseTime(String s) {
    final parts = s.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WMColors.bgPage,
      body: CustomScrollView(
        slivers: [
          // 用户 Header
          SliverToBoxAdapter(child: _buildProfileHeader()),
          SliverPadding(
            padding: const EdgeInsets.all(WMSpacing.md),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── 设备 ───────────────────────────────────────────
                _secTitle('设备'),
                _group([
                  _tappable(
                    icon: Icons.device_hub_outlined,
                    iconBg: WMColors.brandPrimarySoft,
                    iconColor: WMColors.brandPrimaryStrong,
                    title: '醒伴药珠',
                    sub: _deviceLoading
                        ? '设备状态加载中…'
                        : _deviceBattery == null
                            ? (_deviceConnected ? '在线 · 电量未知' : '离线 · 电量未知')
                            : '${_deviceConnected ? "在线" : "离线"} · 电量 $_deviceBattery%',
                    trailing: _deviceLoading
                        ? null
                        : _connectionChip(
                            _deviceConnected ? '已连接' : '未连接', _deviceConnected),
                    onTap: () => context.push('/device'),
                  ),
                  _tappable(
                    icon: Icons.light_mode_outlined,
                    iconBg: WMColors.brandAccentSoft,
                    iconColor: const Color(0xFF8a6020),
                    title: '小醒潮玩公仔',
                    sub: kMockMode ? '待服药 · 暖金常亮' : '灯光状态由设备同步',
                    onTap: () => context.push('/device'),
                  ),
                ]),

                // ── 硬件商城（新增） ────────────────────────────────
                _secTitle('硬件商城'),
                _group([
                  _tappable(
                    icon: Icons.shopping_bag_outlined,
                    iconBg: WMColors.brandAccentSoft,
                    iconColor: const Color(0xFF8a6020),
                    title: '醒伴药珠 & 配件',
                    sub: '药珠定制 / 桌面摆件 / 表链套件',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: WMColors.brandAccent.withOpacity(0.15),
                        border: Border.all(
                            color: WMColors.brandAccent.withOpacity(0.5)),
                        borderRadius: WMRadius.pill,
                      ),
                      child: const Text('进入商城',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8a6020))),
                    ),
                    onTap: () => context.push('/shop'),
                  ),
                  _tappable(
                    icon: Icons.auto_fix_high_outlined,
                    iconBg: WMColors.brandPrimarySoft,
                    iconColor: WMColors.brandPrimary,
                    title: '3D 定制药珠',
                    sub: '上传模型 · 每颗 ¥39 起',
                    onTap: () {
                      context.push('/shop');
                    },
                  ),
                ]),

                // ── 推送设置 ────────────────────────────────────────
                _secTitle('提醒 & 推送'),
                _group([
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: WMSpacing.md, vertical: 12),
                    child: Row(
                      children: [
                        _iconBox(
                            Icons.message_outlined,
                            WMColors.brandSecondarySoft,
                            WMColors.brandSecondary),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('家属推送通知',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500)),
                              Text('服药确认后推送给关注家属',
                                  style: TextStyle(
                                      fontSize: 12, color: WMColors.ink500)),
                            ],
                          ),
                        ),
                        Switch(
                          value: _familyPush,
                          activeColor: WMColors.brandPrimary,
                          onChanged: (v) {
                            final previous = _familyPush;
                            setState(() => _familyPush = v);
                            _saveSetting(
                              'wm_family_push',
                              v,
                              onFailure: () {
                                if (mounted)
                                  setState(() => _familyPush = previous);
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(WMSpacing.md),
                    child: _buildQuietHours(),
                  ),
                  // MVP 约束提示
                  Container(
                    padding: const EdgeInsets.fromLTRB(
                        WMSpacing.md, 0, WMSpacing.md, 12),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 13, color: WMColors.ink500),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'MVP 约束：家属推送打扰感 ≤3/5，超出静默时段不推送',
                            style: const TextStyle(
                                fontSize: 11, color: WMColors.ink500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ]),

                // ── 帮助 ────────────────────────────────────────────
                _secTitle('帮助'),
                _group([
                  _tappable(
                    icon: Icons.chat_bubble_outline,
                    iconBg: WMColors.brandAccentSoft,
                    iconColor: const Color(0xFF8a6020),
                    title: '问问小醒',
                    sub: 'AI 陪伴助手 · 随时解答',
                    onTap: () => context.go('/chat'),
                  ),
                  _tappable(
                    icon: Icons.help_outline,
                    iconBg: WMColors.brandPrimarySoft,
                    iconColor: WMColors.brandPrimary,
                    title: '使用说明',
                    sub: '产品功能与操作指引',
                    onTap: () => _snack('使用说明（即将上线）'),
                  ),
                  _tappable(
                    icon: Icons.delete_outline,
                    iconBg: const Color(0xFFFFECEB),
                    iconColor: WMColors.danger,
                    title: '清除演示数据',
                    sub: '重置本地存储数据',
                    onTap: () => _confirmClear(),
                  ),
                ]),

                // ── 关于 ────────────────────────────────────────────
                _secTitle('关于'),
                _buildAboutCard(),
                const SizedBox(height: 80),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [WMColors.brandPrimaryStrong, WMColors.brandPrimary],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        WMSpacing.md,
        MediaQuery.of(context).padding.top + 12,
        WMSpacing.md,
        WMSpacing.lg,
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
                color: Colors.white24, shape: BoxShape.circle),
            padding: const EdgeInsets.all(6),
            child: Image.asset(
              'assets/images/xiaoxing_login.png',
              fit: BoxFit.contain,
              semanticLabel: '小醒 IP 形象',
            ),
          ),
          const SizedBox(width: 14),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('我的醒伴',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
              Text('患者端 · 醒伴 WakeMate',
                  style: TextStyle(fontSize: 13, color: Colors.white60)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuietHours() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _iconBox(
                Icons.nightlight_outlined, WMColors.bgCream, WMColors.ink700),
            const SizedBox(width: 12),
            const Text('静默时段',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: WMColors.brandPrimarySoft, borderRadius: WMRadius.sm),
          child: Row(
            children: [
              const Icon(Icons.access_time,
                  size: 14, color: WMColors.brandPrimary),
              const SizedBox(width: 6),
              _timeButton(_quietStart, () async {
                final t = await showTimePicker(
                    context: context, initialTime: _quietStart);
                if (t != null) {
                  final previous = _quietStart;
                  setState(() => _quietStart = t);
                  _saveSetting(
                    'wm_quiet_start',
                    _fmtTime(t),
                    onFailure: () {
                      if (mounted) setState(() => _quietStart = previous);
                    },
                  );
                }
              }),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('至',
                    style: TextStyle(fontSize: 13, color: WMColors.ink500)),
              ),
              _timeButton(_quietEnd, () async {
                final t = await showTimePicker(
                    context: context, initialTime: _quietEnd);
                if (t != null) {
                  final previous = _quietEnd;
                  setState(() => _quietEnd = t);
                  _saveSetting(
                    'wm_quiet_end',
                    _fmtTime(t),
                    onFailure: () {
                      if (mounted) setState(() => _quietEnd = previous);
                    },
                  );
                }
              }),
              const SizedBox(width: 6),
              const Text('不推送',
                  style: TextStyle(fontSize: 11, color: WMColors.brandPrimary)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _timeButton(TimeOfDay t, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration:
              BoxDecoration(color: Colors.white, borderRadius: WMRadius.sm),
          child: Text(_fmtTime(t),
              style: const TextStyle(
                fontSize: 14,
                color: WMColors.brandPrimary,
                fontWeight: FontWeight.w600,
              )),
        ),
      );

  Widget _buildAboutCard() {
    return Container(
      padding: const EdgeInsets.all(WMSpacing.lg),
      decoration: BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: WMRadius.lg,
        boxShadow: WMShadows.card,
      ),
      child: Column(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                  colors: [WMColors.brandPrimaryStrong, WMColors.brandPrimary]),
              borderRadius: BorderRadius.all(Radius.circular(18)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SvgPicture.asset(
                'assets/images/wakemate_mark.svg',
                fit: BoxFit.contain,
                semanticsLabel: '醒伴 WakeMate 标志',
              ),
            ),
          ),
          const SizedBox(height: WMSpacing.sm),
          const Text('醒伴 WakeMate',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('伴醒同行 · Wake Together',
              style: TextStyle(
                  fontSize: 14,
                  color: WMColors.brandAccent,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          const Text('v1.0.0-demo · 投资人演示版 · 2026-09',
              style: TextStyle(fontSize: 12, color: WMColors.ink500)),
          Container(
              height: 1,
              width: 40,
              color: WMColors.ink200,
              margin: const EdgeInsets.symmetric(vertical: 8)),
          const Text('出品方：醒时科技 Wakeshift',
              style: TextStyle(fontSize: 13, color: WMColors.ink500)),
          const SizedBox(height: 4),
          const Text(
            '专注睡眠用药管理，以科技连接患者、家属与医疗。\n轻轻叫醒你的小守夜灯。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: WMColors.ink500, height: 1.6),
          ),
        ],
      ),
    );
  }

  // ── 工具组件 ─────────────────────────────────────────────────────
  Widget _secTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(0, WMSpacing.md, 0, 8),
        child: Text(t,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: WMColors.ink500,
              letterSpacing: 0.06,
            )),
      );

  Widget _group(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: WMColors.bgCard,
          borderRadius: WMRadius.lg,
          boxShadow: WMShadows.card,
        ),
        child: ClipRRect(
            borderRadius: WMRadius.lg, child: Column(children: children)),
      );

  Widget _tappable({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String title,
    String? sub,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: WMSpacing.md, vertical: 12),
        child: Row(
          children: [
            _iconBox(icon, iconBg, iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500)),
                  if (sub != null)
                    Text(sub,
                        style: const TextStyle(
                            fontSize: 12, color: WMColors.ink500)),
                ],
              ),
            ),
            trailing ?? const Icon(Icons.chevron_right, color: WMColors.ink300),
          ],
        ),
      ),
    );
  }

  Widget _iconBox(IconData icon, Color bg, Color fg) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: bg, borderRadius: WMRadius.sm),
        child: Icon(icon, size: 18, color: fg),
      );

  Widget _connectionChip(String label, bool connected) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: connected ? WMColors.brandSecondarySoft : WMColors.ink200,
          borderRadius: WMRadius.pill,
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: connected ? const Color(0xFF2C7A6F) : WMColors.ink700,
            )),
      );

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清除演示数据'),
        content: const Text('确认清除所有本地数据？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: WMColors.danger),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final p = await SharedPreferences.getInstance();
      await p.clear();
      if (mounted) context.go('/login');
    }
  }
}
