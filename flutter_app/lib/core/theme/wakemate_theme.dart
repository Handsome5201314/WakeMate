// lib/core/theme/wakemate_theme.dart
// 醒伴 WakeMate 品牌主题
// 严格复用 wakemate-tokens.css 中的设计 Token
// 醒时科技 Wakeshift · v1.0-MVP

import 'package:flutter/material.dart';

// ── 品牌色 ──────────────────────────────────────────────────────
class WMColors {
  WMColors._();

  // 守夜蓝
  static const brandPrimary = Color(0xFF2C4A7E);
  static const brandPrimaryStrong = Color(0xFF223862);
  static const brandPrimaryLight = Color(0xFF6C89B8);
  static const brandPrimarySoft = Color(0xFFE8EEF7);

  // 暖金
  static const brandAccent = Color(0xFFF0B95C);
  static const brandAccentSoft = Color(0xFFFAF0DC);

  // 晨雾青
  static const brandSecondary = Color(0xFF45A79B);
  static const brandSecondarySoft = Color(0xFFE2F1EE);

  // 语义色
  static const success = Color(0xFF3EAF9A);
  static const warning = Color(0xFFE8A13C);
  static const danger = Color(0xFFD9534F);
  static const dangerSoft = Color(0xFFFDECEA);
  static const info = Color(0xFF3E6FD9);

  // 墨色阶
  static const ink900 = Color(0xFF1B2230);
  static const ink700 = Color(0xFF465060);
  static const ink500 = Color(0xFF848DA1);
  static const ink300 = Color(0xFFC2C9D6);
  static const ink200 = Color(0xFFE5E9F0);

  // 背景
  static const bgPage = Color(0xFFF5F7FA);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCream = Color(0xFFF7F3EA);
}

// ── 圆角 ────────────────────────────────────────────────────────
class WMRadius {
  WMRadius._();
  static const lg = BorderRadius.all(Radius.circular(16));
  static const md = BorderRadius.all(Radius.circular(12));
  static const sm = BorderRadius.all(Radius.circular(10));
  static const pill = BorderRadius.all(Radius.circular(999));

  static const double lgValue = 16;
  static const double mdValue = 12;
  static const double smValue = 10;
  static const double pillValue = 999;
}

// ── 阴影 ────────────────────────────────────────────────────────
class WMShadows {
  WMShadows._();

  static const card = [
    BoxShadow(color: Color(0x0F1B2230), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const float = [
    BoxShadow(color: Color(0x1A1B2230), blurRadius: 24, offset: Offset(0, 8)),
  ];
  static const modal = [
    BoxShadow(color: Color(0x291B2230), blurRadius: 40, offset: Offset(0, 12)),
  ];
}

// ── 间距 ────────────────────────────────────────────────────────
class WMSpacing {
  WMSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  static const double touchMin = 44; // 最小触控区域
  static const double tabbarH = 56;
  static const double navbarH = 48;
}

// ── ThemeData ────────────────────────────────────────────────────
ThemeData buildWakeMateTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: WMColors.brandPrimary,
      brightness: Brightness.light,
      primary: WMColors.brandPrimary,
      secondary: WMColors.brandSecondary,
      tertiary: WMColors.brandAccent,
      surface: WMColors.bgCard,
      background: WMColors.bgPage,
      error: WMColors.danger,
    ),
    scaffoldBackgroundColor: WMColors.bgPage,
    fontFamily: 'PingFang SC',
    appBarTheme: const AppBarTheme(
      backgroundColor: WMColors.bgCard,
      foregroundColor: WMColors.ink900,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: WMColors.ink900,
      ),
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: const CardThemeData(
      color: WMColors.bgCard,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: WMRadius.lg),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: WMColors.brandPrimary,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 48),
        shape: const RoundedRectangleBorder(borderRadius: WMRadius.sm),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WMColors.brandPrimary,
        side: const BorderSide(color: WMColors.brandPrimary, width: 1.5),
        minimumSize: const Size(44, 48),
        shape: const RoundedRectangleBorder(borderRadius: WMRadius.sm),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WMColors.bgCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: WMRadius.sm,
        borderSide: const BorderSide(color: WMColors.ink200, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: WMRadius.sm,
        borderSide: const BorderSide(color: WMColors.ink200, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: WMRadius.sm,
        borderSide: const BorderSide(color: WMColors.brandPrimary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: WMColors.ink300, fontSize: 15),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: WMColors.bgCard,
      selectedItemColor: WMColors.brandPrimary,
      unselectedItemColor: WMColors.ink500,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      selectedLabelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 12),
    ),
    dividerTheme: const DividerThemeData(
      color: WMColors.ink200,
      thickness: 1,
      space: 1,
    ),
  );
}
