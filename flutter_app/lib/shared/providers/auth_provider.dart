// lib/shared/providers/auth_provider.dart
// 鉴权状态 Provider
// 醒伴 WakeMate Flutter APP

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/rest_client.dart';

// ── 鉴权状态 ──────────────────────────────────────────────────────
enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  final AuthStatus status;
  final String? userId;
  final String? role;

  const AuthState({
    required this.status,
    this.userId,
    this.role,
  });

  bool get isAuthenticated => status == AuthStatus.authenticated;

  AuthState copyWith({AuthStatus? status, String? userId, String? role}) {
    return AuthState(
      status: status ?? this.status,
      userId: userId ?? this.userId,
      role: role ?? this.role,
    );
  }
}

class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    // 启动时检查本地 token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(kTokenKey);
    final userId = prefs.getString(kUserIdKey);
    if (token != null && userId != null) {
      return AuthState(
        status: AuthStatus.authenticated,
        userId: userId,
        role: prefs.getString('wm_role') ?? 'patient',
      );
    }
    return const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<void> login(String phone, String otp) async {
    state = const AsyncLoading();
    try {
      final api = ref.read(apiProvider);
      final data = await api.login(phone, otp);
      await _setAuthenticatedSession(data);
    } catch (e) {
      state = AsyncData(const AuthState(status: AuthStatus.unauthenticated));
      rethrow;
    }
  }

  Future<void> loginAsDev() async {
    state = const AsyncLoading();
    try {
      final data = await ref.read(apiProvider).loginAsDev();
      await _setAuthenticatedSession(data);
    } catch (e) {
      state = AsyncData(const AuthState(status: AuthStatus.unauthenticated));
      rethrow;
    }
  }

  Future<void> _setAuthenticatedSession(Map<String, dynamic> data) async {
    final accessToken = data['access_token'] as String?;
    final userId = data['user_id'] as String?;
    if (accessToken == null || userId == null) {
      throw const FormatException('登录响应缺少会话信息');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kTokenKey, accessToken);
    await prefs.setString(kUserIdKey, userId);
    await prefs.setString('wm_role', data['role'] as String? ?? 'patient');

    state = AsyncData(AuthState(
      status: AuthStatus.authenticated,
      userId: userId,
      role: data['role'] as String? ?? 'patient',
    ));
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kTokenKey);
    await prefs.remove(kUserIdKey);
    await prefs.remove('wm_role');
    state = const AsyncData(AuthState(status: AuthStatus.unauthenticated));
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
