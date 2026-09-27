// lib/shared/widgets/xiaoxing_avatar.dart
// 小醒头像组件 · 三姿态 SVG 矢量渲染
// gentle（温柔提醒）/ calm（轻声提示）/ soothe（安心安抚）
// 醒伴 WakeMate Flutter APP

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum XiaoxingPose { gentle, calm, soothe }

class XiaoxingAvatar extends StatefulWidget {
  final XiaoxingPose pose;
  final double size;
  final bool animated; // 是否开启呼吸动效
  /// Use the photographic IP artwork shipped with the app. The vector pose
  /// assets remain available for compact legacy surfaces, but the real IP is
  /// the default visual language across the product.
  final bool useIpArtwork;

  const XiaoxingAvatar({
    super.key,
    this.pose = XiaoxingPose.gentle,
    this.size = 40,
    this.animated = false,
    this.useIpArtwork = true,
  });

  @override
  State<XiaoxingAvatar> createState() => _XiaoxingAvatarState();
}

class _XiaoxingAvatarState extends State<XiaoxingAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _breathe;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _breathe = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    if (widget.animated) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(XiaoxingAvatar old) {
    super.didUpdateWidget(old);
    if (widget.animated && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.animated && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _breathe,
      builder: (_, child) => Transform.scale(
        scale: widget.animated ? _breathe.value : 1.0,
        child: child,
      ),
      child: widget.useIpArtwork
          ? Image.asset(
              'assets/images/xiaoxing_login.png',
              width: widget.size,
              height: widget.size,
              fit: BoxFit.contain,
              semanticLabel: '小醒 IP 形象',
            )
          : _VectorPoseAvatar(pose: widget.pose, size: widget.size),
    );
  }
}

class _VectorPoseAvatar extends StatelessWidget {
  final XiaoxingPose pose;
  final double size;

  const _VectorPoseAvatar({required this.pose, required this.size});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      _assetForPose(pose),
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticsLabel: '小醒头像',
    );
  }
}

String _assetForPose(XiaoxingPose pose) {
  switch (pose) {
    case XiaoxingPose.gentle:
      return 'assets/images/xiaoxing_gentle.svg';
    case XiaoxingPose.calm:
      return 'assets/images/xiaoxing_calm.svg';
    case XiaoxingPose.soothe:
      return 'assets/images/xiaoxing_soothe.svg';
  }
}

// ── 姿态工具函数 ──────────────────────────────────────────────────
XiaoxingPose poseFromString(String? s) {
  switch (s) {
    case 'gentle':
      return XiaoxingPose.gentle;
    case 'soothe':
      return XiaoxingPose.soothe;
    default:
      return XiaoxingPose.calm;
  }
}
