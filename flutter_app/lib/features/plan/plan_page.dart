// lib/features/plan/plan_page.dart
// 用药方案页：计划列表 + 本周安排 + 添加/编辑 BottomSheet
// 醒伴 WakeMate Flutter APP

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';

final _plansProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getPlans();
});

class PlanPage extends ConsumerWidget {
  const PlanPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plansAsync = ref.watch(_plansProvider);

    return Scaffold(
      backgroundColor: WMColors.bgPage,
      appBar: AppBar(title: const Text('用药方案')),
      body: plansAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _PlanError(
          onRetry: () => ref.invalidate(_plansProvider),
          onAdd: () => _openSheet(context, ref),
        ),
        data: (plans) => plans.isEmpty
            ? _PlanEmpty(onAdd: () => _openSheet(context, ref))
            : _PlanList(plans: plans, ref: ref),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openSheet(context, ref),
        backgroundColor: WMColors.brandPrimary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  void _openSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: WMColors.bgCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PlanFormSheet(
        api: ref.read(apiProvider),
        onSaved: () => ref.invalidate(_plansProvider),
      ),
    );
  }
}

class _PlanList extends StatelessWidget {
  final List<dynamic> plans;
  final WidgetRef ref;
  const _PlanList({required this.plans, required this.ref});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(WMSpacing.md),
      children: [
        _WeekRow(plans: plans),
        const SizedBox(height: WMSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('我的计划',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WMColors.ink500,
                    letterSpacing: 0.06)),
            Text('共 ${plans.length} 个',
                style: const TextStyle(fontSize: 12, color: WMColors.ink500)),
          ],
        ),
        const SizedBox(height: 10),
        ...plans
            .map((p) => _PlanCard(plan: p as Map<String, dynamic>, ref: ref)),
        const SizedBox(height: 80),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  final WidgetRef ref;
  const _PlanCard({required this.plan, required this.ref});

  @override
  Widget build(BuildContext context) {
    final color = Color(int.parse(
        (plan['color'] ?? '#2C4A7E').replaceFirst('#', 'FF'),
        radix: 16));
    final times = (plan['times'] as List?)?.cast<String>() ?? [];
    final active = plan['active'] as bool? ?? true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(WMSpacing.md),
      decoration: BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: WMRadius.lg,
        boxShadow: WMShadows.card,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 70,
            decoration:
                BoxDecoration(color: color, borderRadius: WMRadius.pill),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan['drug_name'] ?? '',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                Text('每次 ${plan['dosage'] ?? ''}',
                    style:
                        const TextStyle(fontSize: 13, color: WMColors.ink500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: times
                      .map((t) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: WMColors.brandPrimarySoft,
                              borderRadius: WMRadius.pill,
                            ),
                            child: Text(t,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: WMColors.brandPrimary,
                                )),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      plan['synced_to_hw'] == true
                          ? Icons.cloud_done_outlined
                          : Icons.sync_outlined,
                      size: 14,
                      color: plan['synced_to_hw'] == true
                          ? WMColors.brandSecondary
                          : WMColors.warning,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      plan['synced_to_hw'] == true ? '已同步到药珠' : '等待药珠同步',
                      style: TextStyle(
                        fontSize: 12,
                        color: plan['synced_to_hw'] == true
                            ? WMColors.brandSecondary
                            : WMColors.warning,
                      ),
                    ),
                  ],
                ),
                if (plan['note'] != null && (plan['note'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('备注：${plan['note']}',
                        style: const TextStyle(
                            fontSize: 12, color: WMColors.ink500)),
                  ),
              ],
            ),
          ),
          Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: active ? WMColors.brandSecondarySoft : WMColors.ink200,
                  borderRadius: WMRadius.pill,
                ),
                child: Text(active ? '进行中' : '已暂停',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: active
                            ? const Color(0xFF2C7A6F)
                            : WMColors.ink700)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WeekRow extends StatelessWidget {
  final List<dynamic> plans;
  const _WeekRow({required this.plans});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = ['日', '一', '二', '三', '四', '五', '六'];
    final doseCount = plans.fold<int>(
        0, (sum, p) => sum + ((p['times'] as List?)?.length ?? 0));

    return Container(
      padding: const EdgeInsets.all(WMSpacing.md),
      decoration: BoxDecoration(
          color: WMColors.bgCard,
          borderRadius: WMRadius.lg,
          boxShadow: WMShadows.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('本周安排',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (i) {
              final d = now.subtract(Duration(days: now.weekday % 7 - i));
              final isToday = i == now.weekday % 7;
              return Column(
                children: [
                  Text(days[i],
                      style: const TextStyle(
                          fontSize: 11, color: WMColors.ink500)),
                  const SizedBox(height: 4),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isToday
                          ? WMColors.brandPrimary
                          : doseCount > 0
                              ? WMColors.brandPrimarySoft
                              : WMColors.ink200,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('${d.day}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isToday
                                ? Colors.white
                                : doseCount > 0
                                    ? WMColors.brandPrimary
                                    : WMColors.ink500,
                          )),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(doseCount > 0 ? '${doseCount}次' : '',
                      style: const TextStyle(
                          fontSize: 10, color: WMColors.ink500)),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _PlanEmpty extends StatelessWidget {
  final VoidCallback onAdd;
  const _PlanEmpty({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                  color: WMColors.brandPrimarySoft, shape: BoxShape.circle),
              child: Center(
                child: Image.asset(
                  'assets/images/xiaoxing_home.png',
                  width: 56,
                  height: 56,
                  fit: BoxFit.contain,
                  semanticLabel: '小醒空状态插画',
                ),
              ),
            ),
            const SizedBox(height: WMSpacing.md),
            const Text('还没有用药计划',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('点击下方按钮添加第一个计划吧',
                style: TextStyle(fontSize: 15, color: WMColors.ink500),
                textAlign: TextAlign.center),
            const SizedBox(height: WMSpacing.lg),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('添加计划'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(160, 48),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanError extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onAdd;

  const _PlanError({required this.onRetry, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 48, color: WMColors.ink300),
            const SizedBox(height: WMSpacing.md),
            const Text('暂时无法加载用药计划',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: WMSpacing.sm),
            const Text('请检查网络后重试，计划保存状态不会被覆盖。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: WMColors.ink500)),
            const SizedBox(height: WMSpacing.lg),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
                const SizedBox(width: WMSpacing.sm),
                ElevatedButton(onPressed: onAdd, child: const Text('添加计划')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanFormSheet extends StatefulWidget {
  final WakeMateApi api;
  final VoidCallback onSaved;
  const _PlanFormSheet({required this.api, required this.onSaved});

  @override
  State<_PlanFormSheet> createState() => _PlanFormSheetState();
}

class _PlanFormSheetState extends State<_PlanFormSheet> {
  final _nameCtrl = TextEditingController();
  final _dosageCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final List<String> _times = [];
  TimeOfDay _selectedTime = const TimeOfDay(hour: 22, minute: 30);
  String _color = '#2C4A7E';
  bool _saving = false;

  final _colors = ['#2C4A7E', '#45A79B', '#F0B95C', '#D9534F', '#3E6FD9'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _dosageCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _addTime() {
    final t =
        '${_selectedTime.hour.toString().padLeft(2, '0')}:${_selectedTime.minute.toString().padLeft(2, '0')}';
    if (!_times.contains(t)) {
      setState(() {
        _times.add(t);
        _times.sort();
      });
    }
  }

  Future<void> _save(BuildContext context) async {
    if (_saving) return;
    if (_nameCtrl.text.trim().isEmpty ||
        _dosageCtrl.text.trim().isEmpty ||
        _times.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写药名、剂量并至少添加一个服药时间')));
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await widget.api.createPlan({
        'drug_name': _nameCtrl.text.trim(),
        'dosage': _dosageCtrl.text.trim(),
        'times': List<String>.from(_times),
        'note': _noteCtrl.text.trim(),
        'color': _color,
      });
      if (!mounted) return;
      widget.onSaved();
      Navigator.pop(context);
      final synced = result['synced_to_hw'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(synced ? '计划已保存并同步到药珠 ✓' : '计划已保存，等待药珠同步')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('保存失败，请检查网络后重试'), backgroundColor: WMColors.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(WMSpacing.md, 20, WMSpacing.md,
          WMSpacing.md + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('添加用药计划',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: WMSpacing.md),
            TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                    labelText: '药品名称 *', hintText: '如：艾司唑仑片')),
            const SizedBox(height: WMSpacing.md),
            TextField(
                controller: _dosageCtrl,
                decoration: const InputDecoration(
                    labelText: '每次剂量 *', hintText: '如：1片 / 2粒')),
            const SizedBox(height: WMSpacing.md),
            // 服药时间
            const Text('服药时间',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: WMColors.ink700)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                ..._times.map((t) => Chip(
                      label: Text(t,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: WMColors.brandPrimary)),
                      backgroundColor: WMColors.brandPrimarySoft,
                      deleteIconColor: WMColors.brandPrimary,
                      onDeleted: () => setState(() => _times.remove(t)),
                    )),
                ActionChip(
                  label: const Text('+ 添加时间', style: TextStyle(fontSize: 12)),
                  onPressed: () async {
                    final picked = await showTimePicker(
                        context: context, initialTime: _selectedTime);
                    if (picked != null) {
                      setState(() => _selectedTime = picked);
                      _addTime();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: WMSpacing.md),
            TextField(
                controller: _noteCtrl,
                decoration:
                    const InputDecoration(labelText: '备注', hintText: '如：饭后服用')),
            const SizedBox(height: WMSpacing.md),
            Row(
              children: [
                const Text('标签颜色',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: WMColors.ink700)),
                const SizedBox(width: 12),
                ..._colors.map((c) {
                  final col =
                      Color(int.parse(c.replaceFirst('#', 'FF'), radix: 16));
                  return GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 28,
                      height: 28,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == c
                              ? WMColors.ink900
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: WMSpacing.lg),
            ElevatedButton(
              onPressed: _saving ? null : () => _save(context),
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('保存计划'),
            ),
          ],
        ),
      ),
    );
  }
}
