// lib/features/auth/login_page.dart
// 手机号 + OTP 登录页
// 醒伴 WakeMate Flutter APP

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/api/rest_client.dart';
import '../../core/api/ws_client.dart';
import '../../shared/providers/auth_provider.dart';
import '../../shared/widgets/xiaoxing_avatar.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  bool _otpSent = false;
  bool _loading = false;
  String? _otpHint;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    if (_phoneCtrl.text.trim().length != 11) {
      _showError('请输入正确的手机号');
      return;
    }
    setState(() => _loading = true);
    try {
      final result =
          await ref.read(apiProvider).sendOtp(_phoneCtrl.text.trim());
      final devOtp = (result['data'] as Map?)?['otp'] as String?;
      setState(() {
        _otpSent = true;
        _loading = false;
        _otpHint = devOtp == null ? null : '开发模式验证码：$devOtp';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(devOtp == null ? '验证码已发送' : '验证码已发送（开发模式：$devOtp）'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('验证码发送失败：' + _errorMessage(e));
    }
  }

  Future<void> _login() async {
    if (_otpCtrl.text.trim().length < 4) {
      _showError('请输入验证码');
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).login(
            _phoneCtrl.text.trim(),
            _otpCtrl.text.trim(),
          );
      final userId = ref.read(authProvider).valueOrNull?.userId;
      if (userId != null) {
        WakeMateWsClient.instance.connect(userId: userId);
      }
      if (mounted) context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('登录失败：' + _errorMessage(e));
    }
  }

  Future<void> _loginAsDev() async {
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).loginAsDev();
      final userId = ref.read(authProvider).valueOrNull?.userId;
      if (userId != null) {
        WakeMateWsClient.instance.connect(userId: userId);
      }
      if (mounted) context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('开发模式登录失败：' + _errorMessage(e));
    }
  }

  String _errorMessage(Object error) {
    if (error is DioException) {
      final detail = error.response?.data is Map
          ? (error.response?.data as Map)['detail']?.toString()
          : null;
      return detail ?? '网络不可用，请稍后重试';
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
                      style: TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 13,
                      ),
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
                                kDevAuthBypass ? '先进入体验' : '手机号登录',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
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
                              '当前为本地开发环境，无需手机号和验证码即可体验完整界面。',
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
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 12),
                                    child: Text(
                                      '或使用手机号登录',
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
                            controller: _phoneCtrl,
                            keyboardType: TextInputType.phone,
                            maxLength: 11,
                            decoration: const InputDecoration(
                              labelText: '手机号',
                              prefixIcon: Icon(Icons.phone_outlined),
                              prefixText: '+86  ',
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: WMSpacing.md),
                          if (_otpSent) ...[
                            if (_otpHint != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: WMSpacing.sm,
                                ),
                                child: Text(
                                  _otpHint!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: WMColors.brandSecondary,
                                  ),
                                ),
                              ),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _otpCtrl,
                                    keyboardType: TextInputType.number,
                                    maxLength: 6,
                                    decoration: const InputDecoration(
                                      labelText: '验证码',
                                      prefixIcon: Icon(Icons.sms_outlined),
                                      counterText: '',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: WMSpacing.sm),
                                TextButton(
                                  onPressed: _loading ? null : _sendOtp,
                                  child: const Text('重新发送'),
                                ),
                              ],
                            ),
                            const SizedBox(height: WMSpacing.lg),
                            SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: _loading ? null : _login,
                                icon: _loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.login_rounded),
                                label: Text(_loading ? '正在登录…' : '登录'),
                              ),
                            ),
                          ] else ...[
                            SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: _loading ? null : _sendOtp,
                                icon: const Icon(Icons.sms_outlined),
                                label: const Text('获取验证码'),
                              ),
                            ),
                          ],
                          const SizedBox(height: WMSpacing.md),
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
