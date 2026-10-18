// lib/features/home/home_page.dart
// 首页：服药倒计时主卡 + 数字工牌 + 快捷入口 + 提醒浮层
// 醒伴 WakeMate Flutter APP

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';
import '../../core/api/stats_provider.dart';
import '../../core/medication/dose_schedule.dart';

// ── Providers ────────────────────────────────────────────────────
final plansProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getPlans();
});

final homeDosesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  return actionableDoses(await ref.watch(apiProvider).getDoses());
});

final homeDevicesProvider =
    FutureProvider.autoDispose<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getDevices();
});

// ── HomePage ──────────────────────────────────────────────────────
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  Timer? _countdownTimer;
  int _refreshTicks = 0;
  Duration _remaining = Duration.zero;
  Map<String, dynamic>? _nextDose;
  bool _showReminder = false;
  Map<String, dynamic>? _pendingReminder;
  bool _confirmingDose = false;
  final _snoozedUntil = <String, DateTime>{};
  final _remindedDoseIds = <String>{};
  final _confirmationKeys = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshHomeData();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (++_refreshTicks % 30 == 0) ref.invalidate(homeDosesProvider);
      _updateCountdown();
    });
    _updateCountdown();
  }

  void _updateCountdown() {
    final doses = ref.read(homeDosesProvider).valueOrNull;
    if (doses == null) return;
    if (doses.isEmpty) {
      if (mounted &&
          (_nextDose != null || _showReminder || _pendingReminder != null)) {
        setState(() {
          _nextDose = null;
          _showReminder = false;
          _pendingReminder = null;
        });
      }
      return;
    }
    final now = DateTime.now();
    final dose = nextCountdownDose(doses, now)!;
    final scheduled = doseScheduledTime(dose).toLocal();
    final remaining = scheduled.difference(now);
    final time = '${scheduled.hour.toString().padLeft(2, '0')}:'
        '${scheduled.minute.toString().padLeft(2, '0')}';
    if (mounted) {
      setState(() {
        _remaining = remaining.isNegative ? Duration.zero : remaining;
        _nextDose = {...dose, 'next_time': time};
        // A confirmation made elsewhere must close a stale reminder here.
        if (_pendingReminder != null &&
            !doses.any((item) => item['id'] == _pendingReminder!['id'])) {
          _showReminder = false;
          _pendingReminder = null;
        }
      });
      if (!_showReminder && !_confirmingDose) {
        final reminder = nextReminderDose(
          doses,
          now,
          remindedDoseIds: _remindedDoseIds,
          snoozedUntil: _snoozedUntil,
        );
        if (reminder != null) {
          _triggerReminder(reminder, _doseLocalTime(reminder));
        }
      }
    }
  }

  void _triggerReminder(Map<String, dynamic> dose, String time) {
    if (_confirmingDose) return;
    setState(() {
      _showReminder = true;
      _pendingReminder = {...dose, 'time': time};
      if (dose['id'] is String &&
          !doseScheduledTime(dose).isAfter(DateTime.now())) {
        _remindedDoseIds.add(dose['id'] as String);
      }
    });
  }

  String _doseLocalTime(Map<String, dynamic> dose) {
    final scheduled = doseScheduledTime(dose).toLocal();
    return '${scheduled.hour.toString().padLeft(2, '0')}:'
        '${scheduled.minute.toString().padLeft(2, '0')}';
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
                    WMSpacing.md,
                    WMSpacing.sm,
                    WMSpacing.md,
                    0,
                  ),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _buildCountdownCard(),
                      if (_hasHomeDataError) ...[
                        const SizedBox(height: WMSpacing.sm),
                        _buildDataErrorNotice(),
                      ],
                      const SizedBox(height: WMSpacing.md),
                      _buildDoseList(),
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
              Text(
                '醒伴',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  color: WMColors.brandPrimary,
                  height: 1.0,
                ),
              ),
              Text(
                'WakeMate',
                style: TextStyle(
                  fontSize: 13,
                  color: WMColors.brandPrimaryLight,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: WMColors.brandPrimary,
              size: 28,
            ),
            tooltip: '设置',
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownCard() {
    final doses = ref.watch(homeDosesProvider);
    final isDue = _nextDose != null &&
        !doseScheduledTime(_nextDose!).isAfter(DateTime.now().toUtc());
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
                    Text(
                      doses.hasError
                          ? '剂次加载失败'
                          : doses.isLoading && _nextDose == null
                              ? '正在加载今日剂次'
                              : _nextDose == null
                                  ? '今日暂无待确认剂次'
                                  : isDue
                                      ? '到点尚未确认'
                                      : '下一次服药',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: WMColors.brandAccent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _nextDose == null ? '--:--' : nextTime,
                      style: TextStyle(
                        fontSize: compact ? 42 : 48,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 0.98,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _nextDose == null
                          ? '可在方案页查看或添加用药计划'
                          : '$drugName · $dosage',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        height: 1.25,
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 48),
                      child: Text(
                        _nextDose == null
                            ? '让每一次服药都被温柔记住'
                            : isDue
                                ? '请按实际服药情况确认'
                                : '距服药还有 ${_formatRemaining()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: WMColors.brandAccent,
                        ),
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
                    onPressed: doses.hasError
                        ? _refreshHomeData
                        : _nextDose == null
                            ? () => context.go('/plan')
                            : () => _triggerReminder(_nextDose!, nextTime),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WMColors.brandAccent,
                      foregroundColor: WMColors.ink900,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(
                      doses.hasError
                          ? '重新加载'
                          : _nextDose == null
                              ? '查看方案'
                              : '查看剂次',
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDoseList() {
    final doses = ref.watch(homeDosesProvider);
    return Container(
      padding: const EdgeInsets.all(WMSpacing.md),
      decoration: BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: WMRadius.lg,
        boxShadow: WMShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '今日剂次',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: WMSpacing.sm),
          const Text(
            '显示手机当地时间；可选择任意一项查看并确认。',
            style: TextStyle(fontSize: 12, color: WMColors.ink500),
          ),
          doses.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(WMSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => TextButton(
              onPressed: _refreshHomeData,
              child: const Text('剂次加载失败，点击重试'),
            ),
            data: (items) => items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.only(top: WMSpacing.md),
                    child: Text('今日暂无待执行或待确认剂次'),
                  )
                : Column(
                    children: [
                      for (final dose in items)
                        ListTile(
                          key: ValueKey('dose-row-${dose['id']}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${dose['drug_name']} · ${dose['dosage']}',
                          ),
                          subtitle: Text(
                            '${_doseLocalTime(dose)} · '
                            '${doseScheduledTime(dose).isAfter(DateTime.now()) ? '待执行' : '待确认'}',
                          ),
                          trailing: TextButton(
                            key: ValueKey('view-dose-${dose['id']}'),
                            onPressed: _confirmingDose
                                ? null
                                : () => _triggerReminder(
                                      dose,
                                      _doseLocalTime(dose),
                                    ),
                            child: const Text('查看'),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDigitalBadge() {
    final statsAsync = ref.watch(statsProvider);
    final stats = statsAsync.valueOrNull;
    Map<String, dynamic>? todayStats;
    // Stats are ordered by the patient's service timezone, ending with today.
    if (stats != null && stats.isNotEmpty) {
      final item = stats.last;
      if (item is Map<String, dynamic>) {
        todayStats = item;
      }
    }
    final todayRate = (todayStats?['rate'] as num?)?.toDouble();
    final devicesAsync = ref.watch(homeDevicesProvider);
    final devices = devicesAsync.valueOrNull;
    final onlineCount = devices
        ?.where((device) => _isDeviceOnline(_deviceState(device)))
        .length;

    final rateLabel =
        todayRate == null ? '--' : '${todayRate.toStringAsFixed(0)}%';
    final doseCount = ref.watch(homeDosesProvider).valueOrNull?.length;

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
                child: Text(
                  '数字工牌',
                  style: TextStyle(
                    color: WMColors.brandPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
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
                  label: '待确认',
                  value: doseCount == null ? '--' : '$doseCount 项',
                  color: WMColors.brandAccent,
                  background: WMColors.brandAccentSoft,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _badgeStat(
                  label: '在线设备',
                  value: devicesAsync.hasError
                      ? '不可用'
                      : devicesAsync.isLoading
                          ? '加载中'
                          : '${onlineCount ?? 0} 台',
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
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: WMColors.ink700),
        ),
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
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickGrid(BuildContext context) {
    final plans = ref.watch(plansProvider).valueOrNull;
    final devicesAsync = ref.watch(homeDevicesProvider);
    final devices = devicesAsync.valueOrNull;
    final activePlanCount =
        plans?.where((p) => p is Map && p['active'] != false).length;
    final onlineCount = devices
        ?.where((device) => _isDeviceOnline(_deviceState(device)))
        .length;
    final items = [
      (
        icon: Icons.event_note_outlined,
        label: '用药方案',
        sub: activePlanCount == null ? '加载中…' : '$activePlanCount 个进行中',
        color: WMColors.brandPrimarySoft,
        path: '/plan',
      ),
      (
        icon: Icons.dashboard_outlined,
        label: '数据看板',
        sub: '近 7 天趋势',
        color: WMColors.brandSecondarySoft,
        path: '/stats',
      ),
      (
        icon: Icons.device_hub_outlined,
        label: '硬件设备',
        sub: devicesAsync.hasError
            ? '设备数据不可用'
            : devicesAsync.isLoading
                ? '正在加载设备…'
                : devices!.isEmpty
                    ? '尚未绑定醒伴设备'
                    : '${devices.length} 台 · ${onlineCount ?? 0} 台在线',
        color: WMColors.brandAccentSoft,
        path: '/device',
      ),
      (
        icon: Icons.chat_bubble_outline,
        label: '问问小醒',
        sub: 'AI 陪伴助手',
        color: WMColors.brandAccentSoft,
        path: '/chat',
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
          .map(
            (item) => Material(
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
                          color: item.color,
                          borderRadius: WMRadius.sm,
                        ),
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
                                : Icon(
                                    item.icon,
                                    size: 22,
                                    color: WMColors.brandPrimary,
                                  ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: WMColors.ink900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              item.sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: WMColors.ink500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
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
              Text(
                '投资人演示模式',
                style: TextStyle(fontSize: 12, color: Color(0xFF8a6020)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _showReminder = true;
              _pendingReminder = {
                'drug_name': '艾司唑仑片',
                'dosage': '1片',
                'time': '22:30',
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
    final drug = _pendingReminder?['drug_name'] ?? '用药';
    final dosage = _pendingReminder?['dosage'] ?? '--';
    final time = _pendingReminder?['time'] ?? '--:--';
    final canConfirm = kMockMode ||
        (_pendingReminder != null &&
            !doseScheduledTime(
              _pendingReminder!,
            ).isAfter(DateTime.now().toUtc().add(const Duration(minutes: 30))));

    return GestureDetector(
      onTap:
          _confirmingDose ? null : () => setState(() => _showReminder = false),
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
                        color: WMColors.ink200,
                        borderRadius: WMRadius.pill,
                      ),
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
                          child: Text(
                            '请确认这次服药',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$drug · $dosage',
                      key: ValueKey('reminder-dose-${_pendingReminder?['id']}'),
                      style: const TextStyle(
                        fontSize: 15,
                        color: WMColors.ink700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$time（手机当地时间）；只有实际服用后才确认',
                      style: const TextStyle(
                        fontSize: 13,
                        color: WMColors.ink500,
                      ),
                    ),
                    const SizedBox(height: WMSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _confirmingDose
                                ? null
                                : () {
                                    final id = _pendingReminder?['id'];
                                    if (id is String) {
                                      _snoozedUntil[id] = DateTime.now().add(
                                        const Duration(seconds: 30),
                                      );
                                      _remindedDoseIds.remove(id);
                                    }
                                    setState(() => _showReminder = false);
                                    _showSnack(context, '好的，30 秒后再提醒你～');
                                  },
                            child: const Text('稍后提醒'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _confirmingDose || !canConfirm
                                ? null
                                : _confirmPendingDose,
                            child: _confirmingDose
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(canConfirm ? '已服用 ✓' : '尚未到确认时间'),
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
    return state?['status'] == 'online';
  }

  Map<String, dynamic>? _deviceState(Object? device) {
    if (device is! Map) return null;
    final state = device['state'];
    if (state is Map) return Map<String, dynamic>.from(state);
    return Map<String, dynamic>.from(device);
  }

  bool get _hasHomeDataError =>
      ref.watch(plansProvider).hasError ||
      ref.watch(homeDosesProvider).hasError ||
      ref.watch(statsProvider).hasError ||
      ref.watch(homeDevicesProvider).hasError;

  Widget _buildDataErrorNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WMSpacing.md,
        vertical: WMSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: WMColors.dangerSoft,
        borderRadius: WMRadius.sm,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: WMColors.danger,
          ),
          const SizedBox(width: WMSpacing.sm),
          const Expanded(
            child: Text('部分首页数据暂不可用', style: TextStyle(color: WMColors.danger)),
          ),
          TextButton(onPressed: _refreshHomeData, child: const Text('重试')),
        ],
      ),
    );
  }

  void _refreshHomeData() {
    ref.invalidate(plansProvider);
    ref.invalidate(homeDosesProvider);
    ref.invalidate(statsProvider);
    ref.invalidate(homeDevicesProvider);
  }

  Future<void> _confirmPendingDose() async {
    final reminder = _pendingReminder;
    if (reminder == null) return;
    final doseId = reminder['id'];
    if (!kMockMode && (doseId is! String || doseId.isEmpty)) {
      _showSnack(context, '剂次标识无效，请刷新后重试');
      return;
    }
    setState(() => _confirmingDose = true);
    final operationId = _confirmationKeys.putIfAbsent(
      doseId?.toString() ?? 'demo',
      () => const Uuid().v4(),
    );
    try {
      await ref.read(apiProvider).confirmDose({
        'dose_instance_id': doseId,
        'confirmed_by': 'user_tap',
      }, idempotencyKey: operationId);
      if (!mounted) return;
      _confirmationKeys.remove(doseId?.toString() ?? 'demo');
      setState(() {
        _showReminder = false;
        _pendingReminder = null;
        _confirmingDose = false;
      });
      ref.invalidate(statsProvider);
      ref.invalidate(homeDosesProvider);
      _showSnack(context, '服药记录已确认 ✓ 今日继续加油！');
    } catch (_) {
      if (!mounted) return;
      setState(() => _confirmingDose = false);
      _showSnack(context, '确认失败，请检查网络后重试');
    }
  }
}
