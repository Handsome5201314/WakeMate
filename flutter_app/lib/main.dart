// lib/main.dart（更新版）
// 新增 /shop 路由 + WsClient 生命周期管理
// 醒伴 WakeMate Flutter APP

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:opus_codec/opus_codec.dart' as opus_flutter;
import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme/wakemate_theme.dart';
import 'core/api/ws_client.dart';
import 'core/api/rest_client.dart';
import 'features/home/home_page.dart';
import 'features/chat/chat_page.dart';
import 'features/plan/plan_page.dart';
import 'features/stats/stats_page.dart';
import 'features/device/device_page.dart';
import 'features/settings/settings_page.dart';
import 'features/auth/login_page.dart';
import 'features/auth/splash_page.dart';
import 'features/shop/shop_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  await Hive.initFlutter();
  try {
    initOpus(await opus_flutter.load());
  } catch (error) {
    // Voice UI remains available; the session reports a codec error when used.
    debugPrint('[Xiaozhi] Opus codec unavailable: $error');
  }

  runApp(const ProviderScope(child: WakeMateApp()));
}

// ── 路由 ─────────────────────────────────────────────────────────
final _router = GoRouter(
  initialLocation: '/splash',
  redirect: (context, state) async {
    if (state.uri.path == '/splash') return null;
    final prefs = await SharedPreferences.getInstance();
    final isAuthenticated = prefs.getString(kTokenKey) != null &&
        prefs.getString(kUserIdKey) != null;
    final isLoginRoute = state.uri.path == '/login';

    if (!isAuthenticated && !isLoginRoute) return '/login';
    if (isAuthenticated && isLoginRoute) return '/home';
    return null;
  },
  routes: [
    GoRoute(path: '/splash', builder: (_, __) => const SplashPage()),
    GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
    // 商城不在主 TabBar 内，从设置页进入
    GoRoute(path: '/shop', builder: (_, __) => const ShopPage()),
    GoRoute(path: '/device', builder: (_, __) => const DevicePage()),
    ShellRoute(
      builder: (context, state, child) => MainShell(child: child),
      routes: [
        GoRoute(path: '/home', builder: (_, __) => const HomePage()),
        GoRoute(path: '/plan', builder: (_, __) => const PlanPage()),
        GoRoute(path: '/stats', builder: (_, __) => const StatsPage()),
        GoRoute(
            path: '/chat',
            builder: (_, s) => ChatPage(
                  scene: s.uri.queryParameters['scene'],
                  drug: s.uri.queryParameters['drug'],
                )),
        GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
      ],
    ),
  ],
);

class WakeMateApp extends ConsumerStatefulWidget {
  const WakeMateApp({super.key});

  @override
  ConsumerState<WakeMateApp> createState() => _WakeMateAppState();
}

class _WakeMateAppState extends ConsumerState<WakeMateApp> {
  @override
  void initState() {
    super.initState();
    _initWsClient();
  }

  Future<void> _initWsClient() async {
    // 启动时若已登录，初始化 WebSocket 连接
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(kUserIdKey);
    if (userId != null) {
      WakeMateWsClient.instance.connect(userId: userId);
    }
  }

  @override
  void dispose() {
    WakeMateWsClient.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '醒伴 WakeMate',
      debugShowCheckedModeBanner: false,
      theme: buildWakeMateTheme(),
      routerConfig: _router,
      locale: const Locale('zh', 'CN'),
    );
  }
}

// ── 主 Shell（底部 5-Tab） ────────────────────────────────────────
class MainShell extends StatefulWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const _tabs = [
    (
      path: '/home',
      label: '首页',
      icon: Icons.home_outlined,
      activeIcon: Icons.home
    ),
    (
      path: '/plan',
      label: '方案',
      icon: Icons.calendar_today_outlined,
      activeIcon: Icons.calendar_today
    ),
    (
      path: '/stats',
      label: '数据',
      icon: Icons.bar_chart_outlined,
      activeIcon: Icons.bar_chart
    ),
    (
      path: '/chat',
      label: '小醒',
      icon: Icons.chat_bubble_outline,
      activeIcon: Icons.chat_bubble
    ),
    (
      path: '/settings',
      label: '我的',
      icon: Icons.person_outline,
      activeIcon: Icons.person
    ),
  ];

  int _indexForPath(String path) {
    // Shell 内页面可能通过深链进入；高亮状态必须跟随当前路由。
    final index = _tabs.indexWhere(
        (tab) => path == tab.path || path.startsWith('${tab.path}/'));
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = GoRouterState.of(context).uri.path;
    final currentIndex = _indexForPath(currentPath);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: widget.child,
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: WMColors.ink200, width: 1)),
          ),
          child: BottomNavigationBar(
            currentIndex: currentIndex,
            onTap: (i) {
              context.go(_tabs[i].path);
            },
            items: _tabs
                .map((t) => BottomNavigationBarItem(
                      icon: t.path == '/chat'
                          ? const _XiaoxingTabIcon()
                          : Icon(t.icon),
                      activeIcon: t.path == '/chat'
                          ? const _XiaoxingTabIcon(selected: true)
                          : Icon(t.activeIcon),
                      label: t.label,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _XiaoxingTabIcon extends StatelessWidget {
  final bool selected;

  const _XiaoxingTabIcon({this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: selected ? WMColors.brandPrimarySoft : WMColors.bgPage,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? WMColors.brandPrimary : WMColors.ink300,
          width: selected ? 2 : 1.5,
        ),
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/images/xiaoxing_empty.png',
          fit: BoxFit.contain,
          cacheWidth: 96,
          cacheHeight: 96,
          semanticLabel: '小醒',
        ),
      ),
    );
  }
}
