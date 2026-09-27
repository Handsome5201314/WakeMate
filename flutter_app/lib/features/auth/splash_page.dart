import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/rest_client.dart';
import '../../core/theme/wakemate_theme.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1400), _continue);
  }

  Future<void> _continue() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final isAuthenticated = prefs.getString(kTokenKey) != null &&
        prefs.getString(kUserIdKey) != null;
    context.go(isAuthenticated ? '/home' : '/login');
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              WMColors.brandPrimaryStrong,
              WMColors.brandPrimary,
              WMColors.brandPrimaryLight,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              _BrandMark(),
              const SizedBox(height: WMSpacing.lg),
              const Text(
                '醒伴',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
              const SizedBox(height: WMSpacing.sm),
              const Text(
                'WakeMate',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 20,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              const Text(
                '伴醒同行',
                style: TextStyle(
                  color: WMColors.brandAccent,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'Wake Together',
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: WMSpacing.xl),
              const Text(
                '醒时科技 Wakeshift',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: WMSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      height: 112,
      child: SvgPicture.asset(
        'assets/images/wakemate_mark.svg',
        fit: BoxFit.contain,
        semanticsLabel: '醒伴 WakeMate',
      ),
    );
  }
}
