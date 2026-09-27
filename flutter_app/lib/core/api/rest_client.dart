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
// Mock builds can enter the local prototype without a phone number or OTP.
// The flag is intentionally gated by kMockMode so a production build can
// never expose this path accidentally. Pass WAKEMATE_DEV_AUTH_BYPASS=false
// when a mock build needs to exercise the OTP form itself.
const bool kDevAuthBypass = kMockMode &&
    bool.fromEnvironment(
      'WAKEMATE_DEV_AUTH_BYPASS',
      defaultValue: true,
    );
const String kBaseUrl = String.fromEnvironment(
  'WAKEMATE_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

const String kTokenKey = 'wm_access_token';
const String kUserIdKey = 'wm_user_id';

// ── Dio Provider ──────────────────────────────────────────────────
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    baseUrl: kBaseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
  ));

  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(kTokenKey);
      if (token != null) options.headers['Authorization'] = 'Bearer $token';
      handler.next(options);
    },
    onError: (err, handler) async {
      if (err.response?.statusCode == 401) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(kTokenKey);
      }
      handler.next(err);
    },
  ));

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
    final res =
        await _dio.post('/api/auth/login', data: {'phone': phone, 'otp': otp});
    return res.data as Map<String, dynamic>;
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
        'id': 'mock-' + DateTime.now().millisecondsSinceEpoch.toString(),
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
      String id, Map<String, dynamic> data) async {
    final res = await _dio.put('/api/plans/$id', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<void> deletePlan(String id) async {
    await _dio.delete('/api/plans/$id');
  }

  // ── 服药记录 ─────────────────────────────────────────────────────
  Future<Map<String, dynamic>> confirmDose(Map<String, dynamic> data) async {
    if (kMockMode) return {'message': '服药记录已确认', 'data': data};
    final res = await _dio.post('/api/records/confirm', data: data);
    return res.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getRecords({int days = 7}) async {
    if (kMockMode) return const [];
    final res = await _dio.get('/api/records', queryParameters: {'days': days});
    return res.data as List<dynamic>;
  }

  Future<List<dynamic>> getStats({int days = 30}) async {
    if (kMockMode) return _mockStats(days);
    final res =
        await _dio.get('/api/records/stats', queryParameters: {'days': days});
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
      final res = await _dio.get('/api/shop/skus',
          queryParameters: category != null ? {'category': category} : null);
      final data = res.data as Map<String, dynamic>;
      return data['skus'] as List<dynamic>;
    } catch (_) {
      rethrow;
    }
  }

  Future<List<dynamic>> getShopModels({String? category}) async {
    if (kMockMode) return const [];
    try {
      final res = await _dio.get('/api/shop/models',
          queryParameters: category != null ? {'category': category} : null);
      final data = res.data as Map<String, dynamic>;
      return data['models'] as List<dynamic>;
    } catch (_) {
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createShopOrder(
      Map<String, dynamic> data) async {
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
      'rate': rate,
      'streak_days': i + 1,
    };
  });
}

final apiProvider = Provider<WakeMateApi>((ref) {
  return WakeMateApi(ref.watch(dioProvider));
});
