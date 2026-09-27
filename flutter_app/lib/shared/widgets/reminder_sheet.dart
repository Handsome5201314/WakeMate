// lib/shared/widgets/reminder_sheet.dart
// 提醒浮层可复用组件 ReminderBottomSheet
// 从 home_page 内联代码抽取为独立组件，所有需要弹提醒的地方统一调用
// 醒伴 WakeMate Flutter APP · 醒时科技 Wakeshift

import 'package:flutter/material.dart';

import '../../core/theme/wakemate_theme.dart';
import 'xiaoxing_avatar.dart';

class ReminderBottomSheet extends StatelessWidget {
  final String drugName;
  final String dosage;
  final String? scheduledTime;
  final bool isSnoozed; // 稍后提醒再次弹出时标记
  final VoidCallback onConfirm;
  final VoidCallback onSnooze;

  const ReminderBottomSheet({
    super.key,
    required this.drugName,
    required this.dosage,
    this.scheduledTime,
    this.isSnoozed = false,
    required this.onConfirm,
    required this.onSnooze,
  });

  /// 静态方法：弹出提醒浮层
  /// ```dart
  /// ReminderBottomSheet.show(
  ///   context,
  ///   drugName: '艾司唑仑片',
  ///   dosage: '1片',
  ///   onConfirm: () { /* 已服用逻辑 */ },
  ///   onSnooze:  () { /* 稍后提醒逻辑 */ },
  /// );
  /// ```
  static Future<void> show(
    BuildContext context, {
    required String drugName,
    required String dosage,
    String? scheduledTime,
    bool isSnoozed = false,
    required VoidCallback onConfirm,
    required VoidCallback onSnooze,
  }) {
    return showModalBottomSheet(
      context: context,
      isDismissible: false, // 强制用户二选一，不能直接下滑关闭
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => ReminderBottomSheet(
        drugName: drugName,
        dosage: dosage,
        scheduledTime: scheduledTime,
        isSnoozed: isSnoozed,
        onConfirm: onConfirm,
        onSnooze: onSnooze,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    final timeStr = scheduledTime ??
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return Container(
      decoration: const BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: WMShadows.modal,
      ),
      padding: EdgeInsets.fromLTRB(
        WMSpacing.md,
        12,
        WMSpacing.md,
        WMSpacing.md + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽把手
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: WMColors.ink200,
              borderRadius: WMRadius.pill,
            ),
          ),
          const SizedBox(height: WMSpacing.md),

          // 头部：小醒头像 + 提醒标题
          Row(
            children: [
              const XiaoxingAvatar(pose: XiaoxingPose.gentle, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSnoozed ? '别忘了，现在补服也来得及～' : '到服药时间啦～',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: WMColors.ink900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 药品信息
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: WMColors.bgPage,
              borderRadius: WMRadius.md,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: WMColors.brandPrimarySoft,
                    borderRadius: WMRadius.sm,
                  ),
                  child: const Icon(Icons.medication_outlined,
                      size: 20, color: WMColors.brandPrimary),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(drugName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: WMColors.ink900,
                        )),
                    Text('每次 $dosage',
                        style: const TextStyle(
                          fontSize: 13,
                          color: WMColors.ink500,
                        )),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // 来源说明
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 12, color: WMColors.ink500),
              const SizedBox(width: 4),
              Text('由 小醒 温柔提醒 · $timeStr',
                  style: const TextStyle(fontSize: 13, color: WMColors.ink500)),
            ],
          ),
          const SizedBox(height: WMSpacing.md),

          // 操作按钮
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onSnooze();
                  },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('稍后提醒'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onConfirm();
                  },
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: const StadiumBorder(),
                    backgroundColor: WMColors.brandPrimary,
                  ),
                  child: const Text('已服用 ✓'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
