// lib/core/api/rest_client.dart（更新版）
// Dio HTTP 客户端 · JWT 拦截器 + 商城 API + 设置 API
// 醒伴 WakeMate Flutter APP

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── 配置 ─────────────────────────────────────────────────────────
// Mock 仅用于本地原型演示；生产构建使用
// --dart-define=WAKEMATE_MOCK_MODE=false，网络错误会直接交给页面处理。
const bool kMockMode = bool.fromEnvironment(
  'WAKEMATE_MOCK_MODE',
  defaultValue: false,
);
// Mock builds can enter the local prototype without a real account.
// The flag is intentionally gated by kMockMode so a production build can
// never expose this path accidentally. Pass WAKEMATE_DEV_AUTH_BYPASS=false
// when the local bypass must be hidden.
const bool kDevAuthBypass = kMockMode &&
    bool.fromEnvironment('WAKEMATE_DEV_AUTH_BYPASS', defaultValue: true);
const String kBaseUrl = String.fromEnvironment(
  'WAKEMATE_BASE_URL',
  defaultValue: 'https://wakemate.tongyimoheai.top',
);

const String kTokenKey = 'wm_access_token';
const String kUserIdKey = 'wm_user_id';

// AuthNotifier and the router observe this version when a session is removed.
final sessionVersionProvider = StateProvider<int>((ref) => 0);

// Serialize credential writes so an in-flight 401 cannot remove a new login.
Future<void> _sessionMutationTail = Future<void>.value();
Future<T> mutateStoredSession<T>(
  Future<T> Function(SharedPreferences prefs) change,
) {
  final operation = _sessionMutationTail.then((_) async {
    return change(await SharedPreferences.getInstance());
  });
  // The caller still receives the error. Only the queue is recovered here so
  // a failed storage write cannot block every subsequent login/logout.
  _sessionMutationTail = operation.then<void>((_) {}, onError: (Object _) {});
  return operation;
}

// ── Dio Provider ──────────────────────────────────────────────────
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: kBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ),
  );

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString(kTokenKey);
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
        handler.next(options);
      },
      onError: (err, handler) async {
        if (err.response?.statusCode == 401) {
          final removed = await mutateStoredSession((prefs) async {
            final token = prefs.getString(kTokenKey);
            if (token == null ||
                err.requestOptions.headers['Authorization'] !=
                    'Bearer $token') {
              return false;
            }
            await prefs.remove(kTokenKey);
            await prefs.remove(kUserIdKey);
            await prefs.remove('wm_role');
            return true;
          });
          if (removed) {
            ref.read(sessionVersionProvider.notifier).state++;
          }
        }
        handler.next(err);
      },
    ),
  );

  return dio;
});

// ── WakeMateApi ───────────────────────────────────────────────────
class WakeMateApi {
  WakeMateApi(this._dio);
  final Dio _dio;

  // ── 鉴权 ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> sendOtp(String phone) async {
    if (kMockMode) {
      return {
        'message': '验证码已发送',
        'data': {'otp': '123456'},
      };
    }
    final res = await _dio.post('/api/auth/otp', data: {'phone': phone});
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String phone, String otp) async {
    if (kMockMode) {
      if (otp != '123456') {
        throw DioException(
          requestOptions: RequestOptions(path: '/api/auth/login'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/auth/login'),
            statusCode: 401,
            data: {'detail': '验证码错误或已过期'},
          ),
        );
      }
      return {
        'access_token': 'mock-wakemate-token',
        'user_id': 'mock-user',
        'role': 'patient',
        'expires_in': 86400,
      };
    }
    final res = await _dio.post(
      '/api/auth/login',
      data: {'phone': phone, 'otp': otp},
    );
    return res.data as Map<String, dynamic>;
  }

  /// Sign in with the account/password contract used by the production app.
  Future<Map<String, dynamic>> passwordLogin(
    String username,
    String password,
  ) async {
    if (kMockMode) {
      throw StateError('Mock 构建只支持免验证演示，请使用正式版本登录账号');
    }
    final res = await _dio.post(
      '/api/auth/password',
      data: {'username': username, 'password': password},
    );
    return res.data as Map<String, dynamic>;
  }

  /// Create an account and return the newly created session.
  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    String? displayName,
    String timezone = 'Asia/Shanghai',
  }) async {
    if (kMockMode) {
      throw StateError('Mock 构建只支持免验证演示，请使用正式版本注册账号');
    }
    final data = <String, dynamic>{
      'username': username,
      'password': password,
      'timezone': timezone,
    };
    if (displayName != null && displayName.trim().isNotEmpty) {
      data['display_name'] = displayName.trim();
    }
    final res = await _dio.post('/api/auth/register', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMe() async {
    final res = await _dio.get('/api/auth/me');
    return res.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getDoses({String? date}) async {
    if (kMockMode) {
      final day = date == null ? DateTime.now() : DateTime.parse(date);
      return [
        for (final plan in _mockPlans)
          for (final time in plan['times'] as List<String>)
            {
              'id': 'mock-dose-${plan['id']}-$time',
              'dose_instance_id': 'mock-dose-${plan['id']}-$time',
              'plan_id': plan['id'],
              'drug_name': plan['drug_name'],
              'dosage': plan['dosage'],
              'scheduled_time': DateTime(
                day.year,
                day.month,
                day.day,
                int.parse(time.substring(0, 2)),
                int.parse(time.substring(3, 5)),
              ).toUtc().toIso8601String(),
              'status': 'pending',
              'actual_time': null,
              'timezone': DateTime.now().timeZoneName,
            },
      ];
    }
    final res = await _dio.get(
      '/api/doses',
      queryParameters: date == null ? null : {'date': date},
    );
    return res.data as List<dynamic>;
  }

  /// Creates a local-only session for the prototype build.
  ///
  /// This method is unavailable in real builds and never contacts the API.
  Future<Map<String, dynamic>> loginAsDev() async {
    if (!kDevAuthBypass) {
      throw StateError('本地免验证登录仅在 Mock 构建中可用');
    }
    return {
      'access_token': 'dev-wakemate-token',
      'user_id': 'dev-user',
      'role': 'patient',
      'expires_in': 86400,
    };
  }

  Future<void> uploadFcmToken(String fcmToken) async {
    await _dio.post('/api/auth/fcm-token', data: {'fcm_token': fcmToken});
  }

  // ── 用药计划 ─────────────────────────────────────────────────────
  Future<List<dynamic>> getPlans() async {
    if (kMockMode) return List<Map<String, dynamic>>.from(_mockPlans);
    final res = await _dio.get('/api/plans');
    return res.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createPlan(Map<String, dynamic> data) async {
    if (kMockMode) {
      final plan = <String, dynamic>{
        'id': 'mock-${DateTime.now().millisecondsSinceEpoch}',
        ...data,
        'active': true,
        'synced_to_hw': false,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      _mockPlans.add(plan);
      return plan;
    }
    final res = await _dio.post('/api/plans', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updatePlan(
    String id,
    Map<String, dynamic> data,
  ) async {
    final res = await _dio.put('/api/plans/$id', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<void> deletePlan(String id) async {
    await _dio.delete('/api/plans/$id');
  }

  // ── 服药记录 ─────────────────────────────────────────────────────
  Future<Map<String, dynamic>> confirmDose(
    Map<String, dynamic> data, {
    required String idempotencyKey,
  }) async {
    if (kMockMode) return {'message': '服药记录已确认', 'data': data};
    final res = await _dio.post(
      '/api/records/confirm',
      data: data,
      options: Options(headers: {'Idempotency-Key': idempotencyKey}),
    );
    return res.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getRecords({int days = 7}) async {
    if (kMockMode) return const [];
    final res = await _dio.get('/api/records', queryParameters: {'days': days});
    return res.data as List<dynamic>;
  }

  Future<List<dynamic>> getStats({int days = 30}) async {
    if (kMockMode) return _mockStats(days);
    final res = await _dio.get(
      '/api/records/stats',
      queryParameters: {'days': days},
    );
    return res.data as List<dynamic>;
  }

  // ── 设备 ─────────────────────────────────────────────────────────
  Future<List<dynamic>> getDevices() async {
    if (kMockMode) {
      return <Map<String, dynamic>>[
        {
          'id': 'mock-device',
          'device_sn': 'WM-DEMO-001',
          'device_type': 'clasp_bead',
          'status': 'online',
          'bead_total': 7,
          'state': {
            'status': 'online',
            'battery': 78,
            'bead_remain': 5,
            'last_heartbeat': DateTime.now().toUtc().toIso8601String(),
          },
        },
      ];
    }
    final res = await _dio.get('/api/device');
    return res.data as List<dynamic>;
  }

  /// Claim a provisioned device with its one-time code, never by SN alone.
  Future<Map<String, dynamic>> bindDevice({
    required String deviceSn,
    required String claimCode,
    CancelToken? cancelToken,
  }) async {
    if (kMockMode) {
      throw StateError('演示模式不支持认领真实设备，请使用正式版本');
    }
    final res = await _dio.post(
      '/api/device/bind',
      data: {'device_sn': deviceSn, 'claim_code': claimCode},
      cancelToken: cancelToken,
    );
    return res.data as Map<String, dynamic>;
  }

  // ── 用户设置 ─────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getSettings() async {
    if (kMockMode) return _mockSettings;
    try {
      final res = await _dio.get('/api/settings');
      return res.data as Map<String, dynamic>;
    } catch (_) {
      rethrow;
    }
  }

  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> data) async {
    if (kMockMode) {
      _mockSettings.addAll(data);
      return Map<String, dynamic>.from(_mockSettings);
    }
    final res = await _dio.put('/api/settings', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> data) async {
    final res = await _dio.put('/api/settings/profile', data: data);
    return res.data as Map<String, dynamic>;
  }

  // ── 硬件商城 ─────────────────────────────────────────────────────
  Future<List<dynamic>> getShopSkus({String? category}) async {
    if (kMockMode) return const [];
    try {
      final res = await _dio.get(
        '/api/shop/skus',
        queryParameters: category != null ? {'category': category} : null,
      );
      final data = res.data as Map<String, dynamic>;
      return data['skus'] as List<dynamic>;
    } catch (_) {
      rethrow;
    }
  }

  Future<List<dynamic>> getShopModels({String? category}) async {
    if (kMockMode) return const [];
    try {
      final res = await _dio.get(
        '/api/shop/models',
        queryParameters: category != null ? {'category': category} : null,
      );
      final data = res.data as Map<String, dynamic>;
      return data['models'] as List<dynamic>;
    } catch (_) {
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createShopOrder(
    Map<String, dynamic> data,
  ) async {
    final res = await _dio.post('/api/shop/orders', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getMyOrders() async {
    if (kMockMode) return const [];
    try {
      final res = await _dio.get('/api/shop/orders');
      final data = res.data as Map<String, dynamic>;
      return data['orders'] as List<dynamic>;
    } catch (_) {
      rethrow;
    }
  }

  // ── 胸牌/摆件（无鉴权） ───────────────────────────────────────────
  Future<Map<String, dynamic>> getBadgeData(String deviceToken) async {
    final res = await _dio.get('/badge/$deviceToken');
    return res.data as Map<String, dynamic>;
  }
}

final _mockSettings = <String, dynamic>{
  'family_push_enabled': true,
  'quiet_start': '22:00',
  'quiet_end': '07:00',
  'daily_push_limit': 5,
  'snooze_minutes': 15,
  'max_snooze_count': 2,
};

final _mockPlans = <Map<String, dynamic>>[
  {
    'id': 'plan-demo-1',
    'drug_name': '艾司唑仑片',
    'dosage': '1片',
    'times': ['22:30'],
    'note': '睡前服用，不与酒精同服',
    'color': '#2C4A7E',
    'active': true,
    'synced_to_hw': true,
  },
  {
    'id': 'plan-demo-2',
    'drug_name': '褪黑素软糖',
    'dosage': '2粒',
    'times': ['21:30'],
    'note': '睡前 30 分钟',
    'color': '#45A79B',
    'active': true,
    'synced_to_hw': false,
  },
];

List<Map<String, dynamic>> _mockStats(int days) {
  return List.generate(days, (i) {
    final rate = (84.0 + i * 0.4 + (i % 3 == 0 ? -2 : 0)).clamp(70.0, 100.0);
    return {
      'date': DateTime.now()
          .subtract(Duration(days: days - 1 - i))
          .toIso8601String()
          .substring(0, 10),
      'total': 4,
      'ontime': 3,
      'late': 1,
      'missed': 0,
      'unconfirmed': 0,
      'pending': 0,
      'rate': rate,
      'streak_days': i + 1,
    };
  });
}

final apiProvider = Provider<WakeMateApi>((ref) {
  return WakeMateApi(ref.watch(dioProvider));
});
