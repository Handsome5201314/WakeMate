// lib/features/stats/stats_page.dart
// 数据统计页 · fl_chart 柱状/折线/环形 · 品牌配色
// 醒伴 WakeMate Flutter APP

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';

final _statsProvider = FutureProvider<List<dynamic>>((ref) async {
  return ref.watch(apiProvider).getStats(days: 30);
});

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(_statsProvider);

    return Scaffold(
      backgroundColor: WMColors.bgPage,
      body: statsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildError(context, ref),
        data: (stats) {
          final validStats = stats.where(_isValidStat).toList();
          final hasDoseData =
              validStats.any((item) => (item['total'] as num).toInt() > 0);
          return validStats.isEmpty || !hasDoseData
              ? _buildEmpty()
              : _buildBody(context, validStats);
        },
      ),
    );
  }

  bool _isValidStat(dynamic item) {
    if (item is! Map<String, dynamic>) return false;
    final date = item['date']?.toString();
    return date != null &&
        DateTime.tryParse(date) != null &&
        item['rate'] is num &&
        item['total'] is num &&
        item['ontime'] is num &&
        item['late'] is num &&
        item['missed'] is num &&
        item['streak_days'] is num;
  }

  Widget _buildError(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WMSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 48, color: WMColors.ink300),
            const SizedBox(height: WMSpacing.md),
            const Text('暂时无法加载统计数据',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: WMSpacing.sm),
            const Text('请检查网络后重试。',
                style: TextStyle(fontSize: 14, color: WMColors.ink500)),
            const SizedBox(height: WMSpacing.lg),
            OutlinedButton(
              onPressed: () => ref.invalidate(_statsProvider),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(WMSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights_outlined, size: 48, color: WMColors.ink300),
            SizedBox(height: WMSpacing.md),
            Text('完成第一次服药确认后，这里会显示统计',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: WMColors.ink500)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<dynamic> stats) {
    final days7 = stats.length >= 7 ? stats.sublist(stats.length - 7) : stats;
    final days30 = stats;

    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    Map<String, dynamic>? todayStats;
    for (final item in days30) {
      if (item['date']?.toString() == today) {
        todayStats = item as Map<String, dynamic>;
        break;
      }
    }
    final todayRate = (todayStats?['rate'] as num?)?.toDouble();
    final weekRate = days7
            .map((d) => (d['rate'] as num).toDouble())
            .reduce((a, b) => a + b) /
        days7.length;
    final streak = (todayStats?['streak_days'] as num?)?.toInt();

    // 结果分布
    final ontime =
        stats.fold<int>(0, (s, d) => s + ((d['ontime'] as int?) ?? 0));
    final late = stats.fold<int>(0, (s, d) => s + ((d['late'] as int?) ?? 0));
    final missed =
        stats.fold<int>(0, (s, d) => s + ((d['missed'] as int?) ?? 0));

    return CustomScrollView(
      slivers: [
        // 顶部统计英雄区
        SliverToBoxAdapter(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [WMColors.brandPrimaryStrong, WMColors.brandPrimary],
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              WMSpacing.md,
              MediaQuery.of(context).padding.top + 12,
              WMSpacing.md,
              WMSpacing.lg,
            ),
            child: Column(
              children: [
                const Text('数据统计',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
                const SizedBox(height: WMSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _heroStat(
                        todayRate == null
                            ? '--'
                            : '${todayRate.toStringAsFixed(0)}%',
                        '今日按时率',
                        '今日'),
                    _heroStat('${weekRate.toStringAsFixed(0)}%', '本周按时率', '7天'),
                    _heroStat(streak == null ? '--' : '$streak', '连续打卡', '天'),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(WMSpacing.md),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // 近 7 日柱状图
              _chartCard(
                title: '近 7 日按时率',
                sub: '柱状图 · 守夜蓝',
                child: SizedBox(
                  height: 180,
                  child: _BarChart(data: days7),
                ),
              ),
              const SizedBox(height: 12),
              // 近 30 天折线图
              _chartCard(
                title: '近 30 天趋势',
                sub: '折线 · 守夜蓝 + 暖金高点',
                child: SizedBox(
                  height: 180,
                  child: _LineChart(data: days30),
                ),
              ),
              const SizedBox(height: 12),
              // 服药结果环形图
              _chartCard(
                title: '服药结果分布',
                sub: '按时 / 迟到 / 漏服',
                child: SizedBox(
                  height: 220,
                  child: _PieChart(ontime: ontime, late: late, missed: missed),
                ),
              ),
              const SizedBox(height: 80),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _heroStat(String value, String label, String badge) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontFamily: 'DIN Alternate',
            )),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.white60)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Color(0x2EFFFFFF),
            borderRadius: WMRadius.pill,
          ),
          child: Text(badge,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: WMColors.brandAccent,
              )),
        ),
      ],
    );
  }

  Widget _chartCard(
      {required String title, required String sub, required Widget child}) {
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
          Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          Text(sub,
              style: const TextStyle(fontSize: 12, color: WMColors.ink500)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ── 柱状图 ────────────────────────────────────────────────────────
class _BarChart extends StatelessWidget {
  final List<dynamic> data;
  const _BarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final days = ['日', '一', '二', '三', '四', '五', '六'];
    return BarChart(BarChartData(
      minY: 0,
      maxY: 100,
      gridData: FlGridData(
        show: true,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: WMColors.ink200, strokeWidth: 1),
        drawVerticalLine: false,
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: 20,
            getTitlesWidget: (v, _) => Text('${v.toInt()}%',
                style: const TextStyle(fontSize: 11, color: WMColors.ink500)),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= data.length) return const SizedBox();
              final date = DateTime.tryParse(data[i]['date'] as String? ?? '');
              return Text(date != null ? days[date.weekday % 7] : '',
                  style: const TextStyle(fontSize: 11, color: WMColors.ink500));
            },
          ),
        ),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      barGroups: data.asMap().entries.map((e) {
        final rate = (e.value['rate'] as num).toDouble();
        final color = rate >= 95
            ? WMColors.brandPrimary
            : rate >= 85
                ? WMColors.brandSecondary
                : WMColors.warning;
        return BarChartGroupData(
          x: e.key,
          barRods: [
            BarChartRodData(
              toY: rate,
              width: 18,
              color: color,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(6)),
            )
          ],
        );
      }).toList(),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipItem: (group, _, rod, __) => BarTooltipItem(
            '${rod.toY.toStringAsFixed(1)}%',
            const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    ));
  }
}

// ── 折线图 ────────────────────────────────────────────────────────
class _LineChart extends StatelessWidget {
  final List<dynamic> data;
  const _LineChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final spots = data
        .asMap()
        .entries
        .map((e) =>
            FlSpot(e.key.toDouble(), (e.value['rate'] as num).toDouble()))
        .toList();

    return LineChart(LineChartData(
      minY: 0,
      maxY: 100,
      gridData: FlGridData(
        show: true,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: WMColors.ink200, strokeWidth: 1),
        drawVerticalLine: false,
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: 20,
            getTitlesWidget: (v, _) => Text('${v.toInt()}%',
                style: const TextStyle(fontSize: 11, color: WMColors.ink500)),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 5,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= data.length || i % 5 != 0)
                return const SizedBox();
              return Text((data[i]['date'] as String?)?.substring(5) ?? '',
                  style: const TextStyle(fontSize: 10, color: WMColors.ink500));
            },
          ),
        ),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: WMColors.brandPrimary,
          barWidth: 2.5,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
              radius: 3,
              color: WMColors.brandAccent,
              strokeColor: WMColors.brandPrimary,
              strokeWidth: 1,
            ),
          ),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                WMColors.brandPrimary.withOpacity(0.2),
                WMColors.brandPrimary.withOpacity(0)
              ],
            ),
          ),
        ),
      ],
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (spots) => spots
              .map((s) => LineTooltipItem(
                    '${s.y.toStringAsFixed(1)}%',
                    const TextStyle(color: Colors.white, fontSize: 12),
                  ))
              .toList(),
        ),
      ),
    ));
  }
}

// ── 环形图 ────────────────────────────────────────────────────────
class _PieChart extends StatelessWidget {
  final int ontime, late, missed;
  const _PieChart(
      {required this.ontime, required this.late, required this.missed});

  @override
  Widget build(BuildContext context) {
    final total = ontime + late + missed;
    final rate = total > 0 ? (ontime / total * 100) : 0.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 55,
          sections: [
            PieChartSectionData(
                value: ontime.toDouble(),
                color: WMColors.brandPrimary,
                radius: 28,
                title: '',
                borderSide: const BorderSide(color: Colors.white, width: 2)),
            PieChartSectionData(
                value: late.toDouble(),
                color: WMColors.brandAccent,
                radius: 28,
                title: '',
                borderSide: const BorderSide(color: Colors.white, width: 2)),
            PieChartSectionData(
                value: missed.toDouble(),
                color: WMColors.danger,
                radius: 28,
                title: '',
                borderSide: const BorderSide(color: Colors.white, width: 2)),
          ],
        )),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${rate.toStringAsFixed(0)}%',
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: WMColors.brandPrimary)),
            const Text('按时率',
                style: TextStyle(fontSize: 11, color: WMColors.ink500)),
          ],
        ),
      ],
    );
  }
}
