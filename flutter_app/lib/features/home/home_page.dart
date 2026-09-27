// lib/features/home/home_page.dart
// 首页：服药倒计时主卡 + 数字工牌 + 快捷入口 + 提醒浮层
// 醒伴 WakeMate Flutter APP

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';

// ── Providers ────────────────────────────────────────────────────
final plansProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getPlans();
});

final statsProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getStats(days: 7);
});

final homeDevicesProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getDevices();
});

// ── HomePage ──────────────────────────────────────────────────────
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Timer? _countdownTimer;
  Duration _remaining = Duration.zero;
  Map<String, dynamic>? _nextDose;
  bool _showReminder = false;
  Map<String, dynamic>? _pendingReminder;
  bool _confirmingDose = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateCountdown();
    });
    _updateCountdown();
  }

  void _updateCountdown() {
    final plans = ref.read(plansProvider).valueOrNull;
    if (plans == null) return;
    if (plans.isEmpty) {
      if (_nextDose != null && mounted) setState(() => _nextDose = null);
      return;
    }

    final now = DateTime.now();
    var bestRemaining = const Duration(days: 1);
    Map<String, dynamic>? bestPlan;
    String? bestTime;

    for (final item in plans) {
      if (item is! Map<String, dynamic> || item['active'] == false) continue;
      final plan = item;
      final times = (plan['times'] as List?)?.cast<String>() ?? [];
      for (final t in times) {
        final parts = t.split(':');
        if (parts.length < 2) continue;
        final hh = int.tryParse(parts[0]);
        final mm = int.tryParse(parts[1]);
        if (hh == null || mm == null || hh > 23 || mm > 59) continue;
        var target = DateTime(now.year, now.month, now.day, hh, mm);
        if (!target.isAfter(now)) target = target.add(const Duration(days: 1));
        final remaining = target.difference(now);
        if (remaining <= bestRemaining) {
          bestRemaining = remaining;
          bestPlan = plan;
          bestTime = t;
        }
      }
    }

    if (mounted) {
      setState(() {
        _remaining = bestPlan == null ? Duration.zero : bestRemaining;
        _nextDose =
            bestPlan != null ? {...bestPlan, 'next_time': bestTime} : null;
      });

      // 到点触发提醒
      if (bestRemaining.inSeconds <= 1 && !_showReminder && bestPlan != null) {
        _triggerReminder(bestPlan, bestTime ?? '');
      }
    }
  }

  void _triggerReminder(Map<String, dynamic> plan, String time) {
    setState(() {
      _showReminder = true;
      _pendingReminder = {...plan, 'time': time};
    });
  }

  String _formatRemaining() {
    final totalSeconds = _remaining.inSeconds.clamp(0, 24 * 60 * 60);
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: WMColors.bgPage,
            body: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildHeader()),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                      WMSpacing.md, WMSpacing.sm, WMSpacing.md, 0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _buildCountdownCard(),
                      if (_hasHomeDataError) ...[
                        const SizedBox(height: WMSpacing.sm),
                        _buildDataErrorNotice(),
                      ],
                      const SizedBox(height: WMSpacing.md),
                      _buildDigitalBadge(),
                      const SizedBox(height: WMSpacing.md),
                      _buildQuickGrid(context),
                      const SizedBox(height: WMSpacing.md),
                      if (kMockMode) ...[
                        _buildDemoBar(context),
                        const SizedBox(height: WMSpacing.md),
                      ],
                      const SizedBox(height: 24),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          if (_showReminder) _buildReminderSheet(context),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: WMColors.bgCard,
      padding: EdgeInsets.fromLTRB(
        WMSpacing.md,
        MediaQuery.of(context).padding.top + 16,
        WMSpacing.md,
        14,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: SvgPicture.asset('assets/images/wakeshift_mark.svg'),
          ),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('醒伴',
                  style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      color: WMColors.brandPrimary,
                      height: 1.0)),
              Text('WakeMate',
                  style: TextStyle(
                      fontSize: 13,
                      color: WMColors.brandPrimaryLight,
                      letterSpacing: 1.0)),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: WMColors.brandPrimary, size: 28),
            tooltip: '设置',
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownCard() {
    final drugName = _nextDose?['drug_name'] ?? '--';
    final dosage = _nextDose?['dosage'] ?? '--';
    final nextTime = _nextDose?['next_time'] ?? '--:--';

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 350;
        final cardHeight = compact ? 218.0 : 242.0;
        final artWidth = compact ? 132.0 : 154.0;
        return Container(
          height: cardHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [WMColors.brandPrimaryStrong, WMColors.brandPrimary],
            ),
            borderRadius: WMRadius.lg,
            boxShadow: WMShadows.float,
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 122, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_nextDose == null ? '暂无进行中的用药计划' : '下一次服药',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: WMColors.brandAccent,
                        )),
                    const SizedBox(height: 8),
                    Text(_nextDose == null ? '--:--' : nextTime,
                        style: TextStyle(
                          fontSize: compact ? 42 : 48,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 0.98,
                        )),
                    const SizedBox(height: 10),
                    Text(
                      _nextDose == null
                          ? '添加方案后，小醒会准时提醒你'
                          : '$drugName · $dosage',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, color: Colors.white, height: 1.25),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 48),
                      child: Text(
                        _nextDose == null
                            ? '让每一次服药都被温柔记住'
                            : '距服药还有 ${_formatRemaining()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: WMColors.brandAccent),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                width: artWidth,
                height: cardHeight - 8,
                child: Image.asset(
                  'assets/images/xiaoxing_full.png',
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomCenter,
                  cacheWidth: 360,
                  semanticLabel: '小醒陪伴 IP',
                ),
              ),
              Positioned(
                left: 20,
                bottom: 16,
                child: SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    onPressed: _nextDose == null
                        ? () => context.go('/plan')
                        : () => _triggerReminder(_nextDose!, nextTime),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WMColors.brandAccent,
                      foregroundColor: WMColors.ink900,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    child: Text(_nextDose == null ? '添加方案' : '提醒我'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDigitalBadge() {
    final statsAsync = ref.watch(statsProvider);
    final stats = statsAsync.valueOrNull;
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    Map<String, dynamic>? todayStats;
    for (final item in stats ?? const []) {
      if (item is Map<String, dynamic> && item['date']?.toString() == today) {
        todayStats = item;
        break;
      }
    }
    final todayRate = (todayStats?['rate'] as num?)?.toDouble();
    final devices = ref.watch(homeDevicesProvider).valueOrNull;
    final device = _firstDevice(devices);
    final deviceState = device?['state'] is Map
        ? Map<String, dynamic>.from(device!['state'] as Map)
        : device;
    final deviceOnline = _isDeviceOnline(deviceState);

    final rateLabel =
        todayRate == null ? '--' : '${todayRate.toStringAsFixed(0)}%';
    final doseCount = _nextDose == null ? 0 : 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: WMRadius.lg,
        boxShadow: WMShadows.card,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: WMColors.brandPrimarySoft,
                  shape: BoxShape.circle,
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/xiaoxing_empty.png',
                    fit: BoxFit.contain,
                    cacheWidth: 160,
                    cacheHeight: 160,
                    semanticLabel: '小醒头像',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('数字工牌',
                    style: TextStyle(
                        color: WMColors.brandPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: () => _showSnack(context, '工牌截图已生成'),
                icon: const Icon(Icons.ios_share_outlined, size: 18),
                label: const Text('分享'),
                style: TextButton.styleFrom(
                  foregroundColor: WMColors.brandPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(48, 44),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _badgeStat(
                  label: '今日按时率',
                  value: rateLabel,
                  color: WMColors.brandSecondary,
                  background: WMColors.brandSecondarySoft,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _badgeStat(
                  label: '待服药',
                  value: '$doseCount 项',
                  color: WMColors.brandAccent,
                  background: WMColors.brandAccentSoft,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _badgeStat(
                  label: '醒伴药珠',
                  value: deviceOnline ? '在线' : '离线',
                  color: WMColors.brandPrimary,
                  background: WMColors.brandPrimarySoft,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badgeStat({
    required String label,
    required String value,
    required Color color,
    required Color background,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: WMColors.ink700)),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(minHeight: 42),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: WMRadius.sm,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                maxLines: 1,
                style: TextStyle(
                    color: color, fontSize: 20, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickGrid(BuildContext context) {
    final plans = ref.watch(plansProvider).valueOrNull;
    final devices = ref.watch(homeDevicesProvider).valueOrNull;
    final activePlanCount =
        plans?.where((p) => p is Map && p['active'] != false).length;
    final device = _firstDevice(devices);
    final deviceState = device?['state'] is Map
        ? Map<String, dynamic>.from(device!['state'] as Map)
        : device;
    final deviceOnline = _isDeviceOnline(deviceState);
    final items = [
      (
        icon: Icons.event_note_outlined,
        label: '用药方案',
        sub: activePlanCount == null ? '加载中…' : '$activePlanCount 个进行中',
        color: WMColors.brandPrimarySoft,
        path: '/plan'
      ),
      (
        icon: Icons.dashboard_outlined,
        label: '数据看板',
        sub: '近 7 天趋势',
        color: WMColors.brandSecondarySoft,
        path: '/stats'
      ),
      (
        icon: Icons.device_hub_outlined,
        label: '硬件设备',
        sub: device == null ? '未绑定设备' : '药珠 ${deviceOnline ? "在线" : "离线"}',
        color: WMColors.brandAccentSoft,
        path: '/device'
      ),
      (
        icon: Icons.chat_bubble_outline,
        label: '问问小醒',
        sub: 'AI 陪伴助手',
        color: WMColors.brandAccentSoft,
        path: '/chat'
      ),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.52,
      children: items
          .map((item) => Material(
                color: WMColors.bgCard,
                borderRadius: WMRadius.lg,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => context.go(item.path),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                              color: item.color, borderRadius: WMRadius.sm),
                          child: item.path == '/device'
                              ? Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Image.asset(
                                    'assets/images/wakemate_beads_product.png',
                                    fit: BoxFit.contain,
                                    cacheWidth: 128,
                                    semanticLabel: '硬件设备',
                                  ),
                                )
                              : item.path == '/chat'
                                  ? Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Image.asset(
                                        'assets/images/xiaoxing_empty.png',
                                        fit: BoxFit.contain,
                                        cacheWidth: 128,
                                        semanticLabel: '问问小醒',
                                      ),
                                    )
                                  : Icon(item.icon,
                                      size: 22, color: WMColors.brandPrimary),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: WMColors.ink900)),
                              const SizedBox(height: 3),
                              Text(item.sub,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11, color: WMColors.ink500)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }

  Widget _buildDemoBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WMColors.brandAccentSoft,
        borderRadius: WMRadius.sm,
        border: Border.all(color: WMColors.brandAccent.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.circle, size: 6, color: WMColors.brandAccent),
              SizedBox(width: 6),
              Text('投资人演示模式',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8a6020))),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _showReminder = true;
              _pendingReminder = {
                'drug_name': '艾司唑仑片',
                'dosage': '1片',
                'time': '22:30'
              };
            }),
            icon: const Icon(Icons.notifications_active_outlined, size: 18),
            label: const Text('触发服药提醒演示'),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => context.go('/chat?scene=missed&drug=艾司唑仑片'),
            icon: const Icon(Icons.warning_amber_outlined, size: 18),
            label: const Text('模拟漏服场景（跳转小醒）', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildReminderSheet(BuildContext context) {
    final drug = _pendingReminder?['drug_name'] ?? '艾司唑仑片';
    final dosage = _pendingReminder?['dosage'] ?? '1片';

    return GestureDetector(
      onTap: () => setState(() => _showReminder = false),
      child: Container(
        color: Colors.black54,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {}, // 阻止冒泡
            child: Container(
              margin: const EdgeInsets.only(bottom: 80),
              padding: const EdgeInsets.all(WMSpacing.md),
              decoration: const BoxDecoration(
                color: WMColors.bgCard,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                          color: WMColors.ink200, borderRadius: WMRadius.pill),
                    ),
                    const SizedBox(height: WMSpacing.md),
                    Row(
                      children: [
                        Image.asset(
                          'assets/images/xiaoxing_reminder_half.png',
                          width: 52,
                          height: 52,
                          fit: BoxFit.contain,
                          cacheWidth: 150,
                          semanticLabel: '小醒提醒形象',
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('到服药时间啦～',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('$drug · $dosage',
                        style: const TextStyle(
                            fontSize: 15, color: WMColors.ink700)),
                    const SizedBox(height: 4),
                    const Text('由 小醒 温柔提醒',
                        style: TextStyle(fontSize: 13, color: WMColors.ink500)),
                    const SizedBox(height: WMSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() => _showReminder = false);
                              _showSnack(context, '好的，30 秒后再提醒你～');
                            },
                            child: const Text('稍后提醒'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed:
                                _confirmingDose ? null : _confirmPendingDose,
                            child: _confirmingDose
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Text('已服用 ✓'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSnack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  bool _isDeviceOnline(Map<String, dynamic>? state) {
    if (state == null) return false;
    final status = state['status']?.toString();
    if (status == 'online') return true;
    final rawHeartbeat = state['last_heartbeat']?.toString();
    final heartbeat =
        rawHeartbeat == null ? null : DateTime.tryParse(rawHeartbeat);
    if (heartbeat == null) return false;
    return DateTime.now().toUtc().difference(heartbeat.toUtc()).inSeconds <=
        120;
  }

  Map<String, dynamic>? _firstDevice(List<dynamic>? devices) {
    if (devices == null) return null;
    for (final item in devices) {
      if (item is Map<String, dynamic>) return item;
    }
    return null;
  }

  bool get _hasHomeDataError =>
      ref.watch(plansProvider).hasError ||
      ref.watch(statsProvider).hasError ||
      ref.watch(homeDevicesProvider).hasError;

  Widget _buildDataErrorNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: WMSpacing.md, vertical: WMSpacing.sm),
      decoration: BoxDecoration(
        color: WMColors.dangerSoft,
        borderRadius: WMRadius.sm,
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined,
              size: 18, color: WMColors.danger),
          const SizedBox(width: WMSpacing.sm),
          const Expanded(
              child:
                  Text('部分首页数据暂不可用', style: TextStyle(color: WMColors.danger))),
          TextButton(onPressed: _refreshHomeData, child: const Text('重试')),
        ],
      ),
    );
  }

  void _refreshHomeData() {
    ref.invalidate(plansProvider);
    ref.invalidate(statsProvider);
    ref.invalidate(homeDevicesProvider);
  }

  Future<void> _confirmPendingDose() async {
    final reminder = _pendingReminder;
    if (reminder == null) return;
    final scheduled = _scheduledDateTime(reminder['time']?.toString());
    if (scheduled == null) {
      _showSnack(context, '服药时间格式无效，暂时无法确认');
      return;
    }
    setState(() => _confirmingDose = true);
    try {
      await ref.read(apiProvider).confirmDose({
        'reminder_id': reminder['reminder_id']?.toString() ??
            'app-${reminder['id'] ?? 'dose'}-${scheduled.millisecondsSinceEpoch}',
        'plan_id': reminder['id']?.toString() ?? '',
        'drug_name': reminder['drug_name']?.toString() ?? '用药',
        'scheduled_time': scheduled.toIso8601String(),
        'confirmed_by': 'user_tap',
      });
      if (!mounted) return;
      setState(() {
        _showReminder = false;
        _confirmingDose = false;
      });
      ref.invalidate(statsProvider);
      _showSnack(context, '服药记录已确认 ✓ 今日继续加油！');
    } catch (_) {
      if (!mounted) return;
      setState(() => _confirmingDose = false);
      _showSnack(context, '确认失败，请检查网络后重试');
    }
  }

  DateTime? _scheduledDateTime(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour > 23 || minute > 59) return null;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour, minute);
  }
}
