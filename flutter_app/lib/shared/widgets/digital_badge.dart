// lib/shared/widgets/digital_badge.dart
// 数字工牌可复用组件 DigitalBadgeCard
// 用于：home_page / device_page / settings_page
// 醒伴 WakeMate Flutter APP · 醒时科技 Wakeshift

import 'package:flutter/material.dart';

import '../../core/theme/wakemate_theme.dart';
import 'xiaoxing_avatar.dart';

// ── 数据模型 ──────────────────────────────────────────────────────
class BadgeData {
  final String userName;
  final double todayRate; // 0–100
  final int streakDays;
  final bool deviceConnected;
  final int deviceBattery; // 0–100
  final String deviceType; // clasp_bead / desk_companion / badge
  final String toyLightMode; // pending / done / missed
  final XiaoxingPose pose;
  final String? nextDoseTime; // "HH:MM" or null
  final String? nextDrugName;

  const BadgeData({
    required this.userName,
    required this.todayRate,
    required this.streakDays,
    this.deviceConnected = true,
    this.deviceBattery = 100,
    this.deviceType = 'clasp_bead',
    this.toyLightMode = 'pending',
    this.pose = XiaoxingPose.gentle,
    this.nextDoseTime,
    this.nextDrugName,
  });

  BadgeData copyWith({
    double? todayRate,
    int? streakDays,
    bool? deviceConnected,
    int? deviceBattery,
    String? toyLightMode,
    XiaoxingPose? pose,
    String? nextDoseTime,
    String? nextDrugName,
  }) =>
      BadgeData(
        userName: userName,
        todayRate: todayRate ?? this.todayRate,
        streakDays: streakDays ?? this.streakDays,
        deviceConnected: deviceConnected ?? this.deviceConnected,
        deviceBattery: deviceBattery ?? this.deviceBattery,
        deviceType: deviceType,
        toyLightMode: toyLightMode ?? this.toyLightMode,
        pose: pose ?? this.pose,
        nextDoseTime: nextDoseTime ?? this.nextDoseTime,
        nextDrugName: nextDrugName ?? this.nextDrugName,
      );
}

// ── 数字工牌卡片组件 ──────────────────────────────────────────────
class DigitalBadgeCard extends StatelessWidget {
  final BadgeData data;
  final VoidCallback? onShare;
  final VoidCallback? onTapPending;

  const DigitalBadgeCard({
    super.key,
    required this.data,
    this.onShare,
    this.onTapPending,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: WMRadius.lg,
        boxShadow: WMShadows.card,
      ),
      child: Column(
        children: [
          // 顶部彩色渐变条
          Container(
            height: 3,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [WMColors.brandPrimary, WMColors.brandAccent],
              ),
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(WMRadius.lgValue)),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(WMSpacing.md),
            child: Column(
              children: [
                // 头部：头像 + 用户名 + 设备状态
                _buildHeader(),
                const SizedBox(height: 12),

                // 统计格：按时率 + 连续打卡
                _buildStatsGrid(),
                const SizedBox(height: 10),

                // 待服药横条
                if (data.nextDoseTime != null) _buildPendingRow(),
                if (data.nextDoseTime != null) const SizedBox(height: 10),

                // 底部：口号 + 分享按钮
                _buildFooter(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        XiaoxingAvatar(
          pose: data.pose,
          size: 40,
          animated: data.toyLightMode == 'done',
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(data.userName,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: WMColors.ink900)),
              const SizedBox(height: 2),
              Row(
                children: [
                  // 连接状态指示点
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: data.deviceConnected
                          ? WMColors.brandSecondary
                          : WMColors.ink300,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '醒伴药珠 ${data.deviceConnected ? "在线" : "离线"}',
                    style:
                        const TextStyle(fontSize: 12, color: WMColors.ink500),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    data.deviceBattery <= 20
                        ? Icons.battery_alert_outlined
                        : Icons.battery_5_bar_outlined,
                    size: 14,
                    color: data.deviceBattery <= 20
                        ? WMColors.danger
                        : WMColors.brandSecondary,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '${data.deviceBattery}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: data.deviceBattery <= 20
                          ? WMColors.danger
                          : WMColors.ink500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // 公仔灯光状态指示
        _DollLightDot(mode: data.toyLightMode),
      ],
    );
  }

  Widget _buildStatsGrid() {
    final rateColor = data.todayRate >= 90
        ? WMColors.brandSecondary
        : data.todayRate >= 70
            ? WMColors.warning
            : WMColors.danger;

    return Row(
      children: [
        Expanded(
            child: _statCell(
          '今日按时率',
          '${data.todayRate.toStringAsFixed(0)}%',
          rateColor,
        )),
        const SizedBox(width: 8),
        Expanded(
            child: _statCell(
          '连续打卡',
          '${data.streakDays}天',
          WMColors.brandPrimary,
        )),
      ],
    );
  }

  Widget _statCell(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: WMColors.bgPage,
        borderRadius: WMRadius.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: WMColors.ink500)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: color,
                fontFamily: 'DIN Alternate',
              )),
        ],
      ),
    );
  }

  Widget _buildPendingRow() {
    return GestureDetector(
      onTap: onTapPending,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: WMColors.brandPrimarySoft,
          borderRadius: WMRadius.sm,
        ),
        child: Row(
          children: [
            const Icon(Icons.access_time,
                size: 14, color: WMColors.brandPrimary),
            const SizedBox(width: 6),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                      fontSize: 13, color: WMColors.brandPrimary),
                  children: [
                    const TextSpan(
                        text: '待服药 · 下次 ',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    TextSpan(
                      text: data.nextDoseTime ?? '--:--',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontFamily: 'DIN Alternate',
                          fontSize: 14),
                    ),
                    if (data.nextDrugName != null)
                      TextSpan(text: '  ${data.nextDrugName}'),
                  ],
                ),
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 16, color: WMColors.brandPrimary),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('伴醒同行 Wake Together',
            style: TextStyle(fontSize: 12, color: WMColors.ink500)),
        // 分享按钮
        // [预留] 真实实现时调用 HTML2Canvas 或 Flutter screenshot 包截图分享
        // 目前仅显示 Toast 提示
        TextButton.icon(
          onPressed: onShare ??
              () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('工牌截图已生成（预留 screenshot 接口）'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
          icon: const Icon(Icons.share_outlined, size: 14),
          label: const Text('分享', style: TextStyle(fontSize: 13)),
          style: TextButton.styleFrom(
            foregroundColor: WMColors.brandPrimary,
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
          ),
        ),
      ],
    );
  }
}

// ── 公仔灯光状态指示点 ────────────────────────────────────────────
class _DollLightDot extends StatefulWidget {
  final String mode; // pending / done / missed
  const _DollLightDot({required this.mode});

  @override
  State<_DollLightDot> createState() => _DollLightDotState();
}

class _DollLightDotState extends State<_DollLightDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _anim = Tween<double>(begin: 0.2, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    if (widget.mode != 'pending') _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_DollLightDot old) {
    super.didUpdateWidget(old);
    if (widget.mode == 'pending') {
      _ctrl.stop();
      _ctrl.value = 1.0;
    } else {
      if (!_ctrl.isAnimating) _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _color {
    switch (widget.mode) {
      case 'done':
        return WMColors.brandSecondary;
      case 'missed':
        return WMColors.danger;
      default:
        return WMColors.brandAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              _color.withOpacity(widget.mode == 'pending' ? 1.0 : _anim.value),
        ),
      ),
    );
  }
}
