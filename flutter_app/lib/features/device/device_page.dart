// lib/features/device/device_page.dart
// 硬件设备页：醒伴药珠 + 桌面摆件 + BLE 管理
// 醒伴 WakeMate Flutter APP

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';

enum _ToyLight { pending, done, missed }

class DevicePage extends ConsumerStatefulWidget {
  const DevicePage({super.key});

  @override
  ConsumerState<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends ConsumerState<DevicePage>
    with TickerProviderStateMixin {
  bool _connected = false;
  bool _hasDevice = false;
  int? _battery;
  int? _beadRemain;
  int? _beadTotal;
  bool _loadingDevice = true;
  String? _deviceError;
  _ToyLight _lightMode = _ToyLight.pending;

  late AnimationController _breatheCtrl;
  late AnimationController _flashCtrl;
  late Animation<double> _breatheAnim;
  late Animation<double> _flashAnim;

  @override
  void initState() {
    super.initState();
    _breatheCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
    _flashCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);
    _breatheAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _breatheCtrl, curve: Curves.easeInOut));
    _flashAnim = Tween<double>(begin: 0.1, end: 1.0)
        .animate(CurvedAnimation(parent: _flashCtrl, curve: Curves.easeInOut));
    _loadDevice();
  }

  Future<void> _loadDevice() async {
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
      if (device == null) {
        setState(() {
          _loadingDevice = false;
          _deviceError = null;
          _hasDevice = false;
          _connected = false;
          _battery = null;
          _beadRemain = null;
          _beadTotal = null;
        });
        return;
      }
      final rawState = device['state'];
      final state =
          rawState is Map ? Map<String, dynamic>.from(rawState) : device;
      setState(() {
        _loadingDevice = false;
        _deviceError = null;
        _hasDevice = true;
        _connected = _isDeviceOnline(state);
        _battery = (state?['battery'] as num?)?.toInt();
        _beadTotal = (device?['bead_total'] as num?)?.toInt();
        _beadRemain = (state?['bead_remain'] as num?)?.toInt();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingDevice = false;
        _deviceError = '设备状态加载失败，请检查网络后重试';
        _hasDevice = false;
        _connected = false;
        _battery = null;
        _beadRemain = null;
        _beadTotal = null;
      });
    }
  }

  @override
  void dispose() {
    _breatheCtrl.dispose();
    _flashCtrl.dispose();
    super.dispose();
  }

  Color get _lightColor {
    switch (_lightMode) {
      case _ToyLight.pending:
        return WMColors.brandAccent;
      case _ToyLight.done:
        return WMColors.brandSecondary;
      case _ToyLight.missed:
        return WMColors.brandAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WMColors.bgPage,
      appBar: AppBar(title: const Text('硬件设备')),
      body: _loadingDevice
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(WMSpacing.md),
              children: [
                if (_deviceError != null)
                  _buildDeviceError()
                else if (!_hasDevice)
                  _buildDeviceEmpty()
                else ...[
                  if (!_connected) _buildDeviceEmpty(),
                  _buildBeadCard(),
                  const SizedBox(height: 12),
                  _buildDollCard(),
                  const SizedBox(height: 12),
                  _buildMiniBadge(),
                  const SizedBox(height: 80),
                ],
              ],
            ),
    );
  }

  Widget _buildDeviceError() {
    return Container(
      margin: const EdgeInsets.only(bottom: WMSpacing.md),
      padding: const EdgeInsets.all(WMSpacing.md),
      decoration: BoxDecoration(
        color: WMColors.dangerSoft,
        borderRadius: WMRadius.md,
        border: Border.all(color: WMColors.danger.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, color: WMColors.danger),
          const SizedBox(width: WMSpacing.sm),
          const Expanded(
              child: Text('设备状态暂不可用，请稍后重试',
                  style: TextStyle(color: WMColors.danger))),
          TextButton(onPressed: _loadDevice, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildDeviceEmpty() {
    return Container(
      margin: const EdgeInsets.only(bottom: WMSpacing.md),
      padding: const EdgeInsets.all(WMSpacing.md),
      decoration: BoxDecoration(
        color: WMColors.brandPrimarySoft,
        borderRadius: WMRadius.md,
      ),
      child: const Row(
        children: [
          Icon(Icons.bluetooth_disabled_outlined, color: WMColors.brandPrimary),
          SizedBox(width: WMSpacing.sm),
          Expanded(
              child: Text('还没有在线的醒伴药珠，请先完成设备配对。',
                  style: TextStyle(color: WMColors.brandPrimary))),
        ],
      ),
    );
  }

  // ── 醒伴药珠状态卡 ──────────────────────────────────────────────
  Widget _buildBeadCard() {
    return Container(
      padding: const EdgeInsets.all(WMSpacing.md),
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
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: WMColors.brandPrimarySoft,
                  borderRadius: WMRadius.sm,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Image.asset(
                    'assets/images/wakemate_beads.png',
                    fit: BoxFit.contain,
                    semanticLabel: '醒伴药珠',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('醒伴药珠',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text('ESP32-S3 · 醒时科技',
                      style: TextStyle(fontSize: 12, color: WMColors.ink500)),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _connected
                      ? WMColors.brandSecondarySoft
                      : WMColors.brandAccentSoft,
                  borderRadius: WMRadius.pill,
                ),
                child: Text(
                  _connected ? '已连接' : '未连接',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: _connected
                        ? const Color(0xFF2C7A6F)
                        : const Color(0xFF8a6020),
                  ),
                ),
              ),
            ],
          ),

          // 刻度环可视化
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: _BeadRing(remain: _beadRemain, total: _beadTotal),
          ),

          // 信息行
          _infoRow(
            '连接状态',
            _connected ? '已连接' : '未连接',
            trailing: OutlinedButton(
              onPressed: _loadDevice,
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: Size.zero,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('刷新', style: TextStyle(fontSize: 12)),
            ),
          ),
          const Divider(height: 1),
          _infoRow(
            '电量',
            _battery == null ? '--' : '$_battery%',
            valueWidget: Row(
              children: [
                Text(_battery == null ? '--' : '$_battery%',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _battery != null && _battery! <= 20
                          ? WMColors.danger
                          : WMColors.ink900,
                    )),
                if (_battery != null) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    child: LinearProgressIndicator(
                      value: _battery! / 100,
                      backgroundColor: WMColors.ink200,
                      color: _battery! <= 20
                          ? WMColors.danger
                          : WMColors.brandSecondary,
                      borderRadius: WMRadius.pill,
                      minHeight: 6,
                    ),
                  ),
                ],
              ],
            ),
            trailing: kMockMode && _battery != null
                ? OutlinedButton(
                    onPressed: () {
                      setState(() =>
                          _battery = (_battery! - 10).clamp(0, 100).toInt());
                      if (_battery! <= 20) _showSnack('电量低，请及时充电');
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('-10%', style: TextStyle(fontSize: 12)),
                  )
                : null,
          ),
          const Divider(height: 1),
          _infoRow(
            '药仓余量',
            '${_beadRemain ?? '--'} / ${_beadTotal ?? '--'} 格',
            trailing: kMockMode && _beadRemain != null
                ? ElevatedButton(
                    onPressed: () {
                      if (_beadRemain! > 0)
                        setState(() => _beadRemain = _beadRemain! - 1);
                      _showSnack('药珠开盖事件已触发；开盖不等于服药确认');
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WMColors.brandAccent,
                      foregroundColor: WMColors.ink900,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('模拟开盖', style: TextStyle(fontSize: 12)),
                  )
                : null,
          ),

          // 架构注释提示
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: WMColors.brandAccentSoft,
              borderRadius: WMRadius.sm,
              border: Border.all(color: WMColors.brandAccent.withOpacity(0.4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: Color(0xFF8a6020)),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '药盒本体不联网 · 用药计划固化本地 RTC · 联网仅用于事件同步',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8a6020)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 小醒潮玩公仔状态卡 ────────────────────────────────────────────
  Widget _buildDollCard() {
    return Container(
      padding: const EdgeInsets.all(WMSpacing.md),
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
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: WMColors.brandAccentSoft, borderRadius: WMRadius.sm),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.asset(
                    'assets/images/xiaoxing_doll.png',
                    fit: BoxFit.contain,
                    semanticLabel: '小醒潮玩公仔',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('小醒潮玩公仔',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text('实体灯光状态映射',
                      style: TextStyle(fontSize: 12, color: WMColors.ink500)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 公仔灯光可视化
          AnimatedBuilder(
            animation: _lightMode == _ToyLight.done ? _breatheAnim : _flashAnim,
            builder: (_, child) {
              double opacity = _lightMode == _ToyLight.pending
                  ? 1.0
                  : _lightMode == _ToyLight.done
                      ? _breatheAnim.value
                      : _flashAnim.value;
              return Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _lightColor.withOpacity(opacity * 0.3),
                    ),
                  ),
                  Image.asset(
                    'assets/images/xiaoxing_doll.png',
                    width: 72,
                    height: 72,
                    fit: BoxFit.contain,
                    semanticLabel: '小醒潮玩公仔状态',
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // 当前状态标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: _lightMode == _ToyLight.done
                  ? WMColors.brandSecondarySoft
                  : _lightMode == _ToyLight.missed
                      ? const Color(0xFFFFECEB)
                      : WMColors.brandAccentSoft,
              borderRadius: WMRadius.pill,
            ),
            child: Text(
              !kMockMode
                  ? '状态待同步'
                  : _lightMode == _ToyLight.pending
                      ? '待服药'
                      : _lightMode == _ToyLight.done
                          ? '已完成'
                          : '漏服提醒',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: !kMockMode
                    ? WMColors.ink500
                    : _lightMode == _ToyLight.done
                        ? const Color(0xFF2C7A6F)
                        : _lightMode == _ToyLight.missed
                            ? WMColors.danger
                            : const Color(0xFF8a6020),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 状态切换按钮
          if (kMockMode)
            Row(
              children: _ToyLight.values.map((mode) {
                final isActive = _lightMode == mode;
                final labels = ['待服药', '已完成', '漏服提醒'];
                final subs = ['暖金常亮', '晨雾青呼吸', '暖金慢闪'];
                final idx = _ToyLight.values.indexOf(mode);
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _lightMode = mode);
                      _showSnack('公仔灯光已切换：${labels[idx]}（${subs[idx]}）');
                    },
                    child: Container(
                      margin: EdgeInsets.only(left: idx == 0 ? 0 : 6),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isActive ? _lightColor : WMColors.ink200,
                          width: isActive ? 1.5 : 1,
                        ),
                        borderRadius: WMRadius.md,
                        color: isActive
                            ? _lightColor.withOpacity(0.1)
                            : WMColors.bgCard,
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: [
                                WMColors.brandAccent,
                                WMColors.brandSecondary,
                                WMColors.brandAccent
                              ][idx],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(labels[idx],
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: isActive
                                    ? WMColors.ink900
                                    : WMColors.ink700,
                              )),
                          Text(subs[idx],
                              style: const TextStyle(
                                  fontSize: 10, color: WMColors.ink500)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            )
          else
            const Text(
              '灯光状态由设备事件同步，当前页面不会伪造硬件状态。',
              style: TextStyle(fontSize: 12, color: WMColors.ink500),
            ),
        ],
      ),
    );
  }

  Widget _buildMiniBadge() {
    return Container(
      padding: const EdgeInsets.all(WMSpacing.md),
      decoration: BoxDecoration(
        color: WMColors.bgCard,
        borderRadius: WMRadius.lg,
        boxShadow: WMShadows.card,
      ),
      child: Row(
        children: [
          Image.asset(
            'assets/images/xiaoxing_login.png',
            width: 40,
            height: 40,
            fit: BoxFit.contain,
            semanticLabel: '小醒 IP 形象',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('醒伴 WakeMate',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _connected
                            ? WMColors.brandSecondary
                            : WMColors.ink300,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('药珠 ${_connected ? "在线" : "离线"}',
                        style: const TextStyle(
                            fontSize: 12, color: WMColors.ink500)),
                    const SizedBox(width: 4),
                    Icon(
                      _battery != null && _battery! <= 20
                          ? Icons.battery_alert_outlined
                          : Icons.battery_5_bar_outlined,
                      size: 14,
                      color: _battery != null && _battery! <= 20
                          ? WMColors.danger
                          : WMColors.brandSecondary,
                    ),
                    const SizedBox(width: 2),
                    Text('${_battery ?? "--"}%',
                        style: const TextStyle(
                            fontSize: 12, color: WMColors.ink500)),
                  ],
                ),
              ],
            ),
          ),
          const Text('伴醒同行',
              style: TextStyle(fontSize: 12, color: WMColors.ink500)),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value,
      {Widget? valueWidget, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style:
                      const TextStyle(fontSize: 14, color: WMColors.ink500))),
          Expanded(
              child: valueWidget ??
                  Text(value,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600))),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  bool _isDeviceOnline(Map<String, dynamic>? state) {
    if (state == null) return false;
    if (state['status']?.toString() == 'online') return true;
    final rawHeartbeat = state['last_heartbeat']?.toString();
    final heartbeat =
        rawHeartbeat == null ? null : DateTime.tryParse(rawHeartbeat);
    if (heartbeat == null) return false;
    final age = DateTime.now().toUtc().difference(heartbeat.toUtc()).inSeconds;
    return age >= 0 && age <= 120;
  }
}

// ── 药珠刻度环 ────────────────────────────────────────────────────
class _BeadRing extends StatelessWidget {
  final int? remain, total;
  const _BeadRing({required this.remain, required this.total});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 140,
      child:
          CustomPaint(painter: _BeadRingPainter(remain: remain, total: total)),
    );
  }
}

class _BeadRingPainter extends CustomPainter {
  final int? remain, total;
  _BeadRingPainter({required this.remain, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const r = 52.0;

    // 底圆
    canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = WMColors.ink200
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8);

    // 进度弧（暖金）
    final ratio = total != null && total! > 0 && remain != null
        ? (remain! / total!).clamp(0.0, 1.0)
        : 0.0;
    final sweepAngle = 2 * 3.14159 * ratio.toDouble();
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -3.14159 / 2,
      sweepAngle,
      false,
      Paint()
        ..color = remain == null
            ? WMColors.ink300
            : remain == 0
                ? WMColors.danger
                : WMColors.brandAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );

    // 中心圆
    canvas.drawCircle(
        Offset(cx, cy), 38, Paint()..color = WMColors.brandPrimary);
    canvas.drawCircle(Offset(cx, cy), 22,
        Paint()..color = WMColors.brandAccent.withOpacity(0.2));
    canvas.drawCircle(
        Offset(cx, cy), 10, Paint()..color = WMColors.brandAccent);

    // 余量文字
    _drawText(canvas, '余量', Offset(cx, cy - 9), 10, Colors.white60);
    _drawText(
        canvas,
        remain == null || total == null ? '--/--' : '$remain/$total',
        Offset(cx, cy + 8),
        16,
        Colors.white);
  }

  void _drawText(
      Canvas c, String text, Offset offset, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              fontSize: size, color: color, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, offset - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_BeadRingPainter old) =>
      old.remain != remain || old.total != total;
}
