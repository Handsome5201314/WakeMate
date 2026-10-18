// lib/features/auth/login_page.dart
// 账号密码登录与注册页
// 醒伴 WakeMate Flutter APP

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';
import '../../shared/providers/auth_provider.dart';
import '../../shared/widgets/xiaoxing_avatar.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  bool _registering = false;
  bool _obscurePassword = true;
  bool _loading = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (!RegExp(r'^[A-Za-z0-9_]{3,32}$').hasMatch(username)) {
      _showError('账号需为 3-32 位字母、数字或下划线');
      return;
    }
    if (password.length < 12) {
      _showError('密码至少需要 12 位');
      return;
    }
    setState(() => _loading = true);
    try {
      final auth = ref.read(authProvider.notifier);
      if (_registering) {
        await auth.register(
          username: username,
          password: password,
          displayName: _displayNameCtrl.text.trim().isEmpty
              ? null
              : _displayNameCtrl.text.trim(),
        );
      } else {
        await auth.loginWithPassword(username, password);
      }
      if (mounted) context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError((_registering ? '注册失败：' : '登录失败：') + _errorMessage(e));
    }
  }

  Future<void> _loginAsDev() async {
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).loginAsDev();
      if (mounted) context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('开发模式登录失败：' + _errorMessage(e));
    }
  }

  String _errorMessage(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is DioException) {
      if (error.response?.statusCode == 401) return '账号或密码错误，请重新输入';
      if (error.response?.statusCode == 409) return '账号已存在，请直接登录';
      if (error.response?.statusCode == 429) return '操作过于频繁，请稍后重试';
      final data = error.response?.data;
      final detail = data is Map ? data['detail'] : null;
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] != null)
          return first['msg'].toString();
      }
      return '网络不可用，请稍后重试';
    }
    return '请稍后重试';
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: WMColors.danger),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WMColors.bgPage,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [WMColors.brandPrimaryStrong, WMColors.brandPrimary],
            stops: [0, .58],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              WMSpacing.lg,
              WMSpacing.lg,
              WMSpacing.lg,
              WMSpacing.md,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  children: [
                    const SizedBox(height: WMSpacing.sm),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SvgPicture.asset(
                          'assets/images/wakemate_mark.svg',
                          width: 30,
                          height: 30,
                          semanticsLabel: '醒伴 WakeMate 标志',
                        ),
                        const SizedBox(width: WMSpacing.sm),
                        const Text(
                          '醒伴 WakeMate',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: WMSpacing.lg),
                    ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(28)),
                      child: Image.asset(
                        'assets/images/xiaoxing_login.png',
                        width: 124,
                        height: 160,
                        fit: BoxFit.contain,
                        semanticLabel: '小醒陪伴 IP',
                      ),
                    ),
                    const SizedBox(height: WMSpacing.md),
                    const Text(
                      '小醒在这里，陪你稳稳醒来',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: WMSpacing.xs),
                    const Text(
                      'Wake together · 每一个夜晚都有回应',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
                    ),
                    const SizedBox(height: WMSpacing.xl),
                    Container(
                      padding: const EdgeInsets.fromLTRB(
                        WMSpacing.lg,
                        WMSpacing.lg,
                        WMSpacing.lg,
                        WMSpacing.md,
                      ),
                      decoration: BoxDecoration(
                        color: WMColors.bgCard,
                        borderRadius: WMRadius.lg,
                        boxShadow: WMShadows.modal,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const XiaoxingAvatar(
                                size: 28,
                                pose: XiaoxingPose.gentle,
                              ),
                              const SizedBox(width: WMSpacing.sm),
                              Text(
                                _registering ? '创建醒伴账号' : '账号登录',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: WMColors.ink900,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ),
                          if (kDevAuthBypass) ...[
                            const SizedBox(height: WMSpacing.sm),
                            const Text(
                              '当前为本地开发环境，可免验证体验完整界面。',
                              style: TextStyle(
                                color: WMColors.ink500,
                                fontSize: 13,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: WMSpacing.md),
                            SizedBox(
                              height: 52,
                              child: ElevatedButton.icon(
                                onPressed: _loading ? null : _loginAsDev,
                                icon: _loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.arrow_forward_rounded),
                                label: Text(_loading ? '正在进入…' : '免验证进入体验'),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: WMSpacing.md,
                              ),
                              child: Row(
                                children: [
                                  Expanded(child: Divider()),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Text(
                                      '或使用账号密码',
                                      style: TextStyle(
                                        color: WMColors.ink500,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(child: Divider()),
                                ],
                              ),
                            ),
                          ],
                          TextField(
                            controller: _usernameCtrl,
                            keyboardType: TextInputType.text,
                            maxLength: 32,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: '账号',
                              hintText: '字母、数字或下划线',
                              prefixIcon: Icon(Icons.person_outline),
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: WMSpacing.md),
                          if (_registering) ...[
                            TextField(
                              controller: _displayNameCtrl,
                              maxLength: 100,
                              decoration: const InputDecoration(
                                labelText: '昵称（可选）',
                                prefixIcon: Icon(Icons.badge_outlined),
                                counterText: '',
                              ),
                            ),
                            const SizedBox(height: WMSpacing.md),
                          ],
                          TextField(
                            controller: _passwordCtrl,
                            obscureText: _obscurePassword,
                            maxLength: 128,
                            onSubmitted: (_) {
                              if (!_loading && !kMockMode) _login();
                            },
                            decoration: InputDecoration(
                              labelText: '密码',
                              hintText: '至少 12 位',
                              prefixIcon: const Icon(Icons.lock_outline),
                              counterText: '',
                              suffixIcon: IconButton(
                                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                                onPressed: () => setState(() {
                                  _obscurePassword = !_obscurePassword;
                                }),
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: WMSpacing.lg),
                          SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _loading || kMockMode ? null : _login,
                              icon: _loading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _registering
                                          ? Icons.person_add_alt_1
                                          : Icons.login_rounded,
                                    ),
                              label: Text(
                                _loading
                                    ? (_registering ? '正在注册…' : '正在登录…')
                                    : (_registering ? '注册并进入' : '登录'),
                              ),
                            ),
                          ),
                          const SizedBox(height: WMSpacing.sm),
                          TextButton(
                            onPressed: _loading || kMockMode
                                ? null
                                : () => setState(() {
                                    _registering = !_registering;
                                    _passwordCtrl.clear();
                                  }),
                            child: Text(
                              _registering ? '已有账号，直接登录' : '没有账号，注册新账号',
                            ),
                          ),
                          const SizedBox(height: WMSpacing.md),
                          if (kMockMode)
                            const Padding(
                              padding: EdgeInsets.only(bottom: WMSpacing.sm),
                              child: Text(
                                '演示版本不会创建真实账号。账号注册和密码登录请使用正式版本。',
                                style: TextStyle(
                                  color: WMColors.ink500,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          const Text(
                            '登录即表示同意《用户协议》和《隐私政策》',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: WMColors.ink500,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: WMSpacing.lg),
                    const Text(
                      '醒时科技 Wakeshift · 出品',
                      style: TextStyle(fontSize: 11, color: Color(0x99FFFFFF)),
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
}
