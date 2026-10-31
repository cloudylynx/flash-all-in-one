import 'package:flutter/material.dart';

/// 应用主题
///
/// 设计取向：
/// - 深色为主（工程工具常用）
/// - 强调色用青蓝色（科技感）
/// - 圆角适中，不圆润也不硬朗
class AppTheme {
  AppTheme._();

  // ── 调色板 ──
  static const Color primary = Color(0xFF3B82F6);      // 蓝
  static const Color primaryDark = Color(0xFF2563EB);
  static const Color accent = Color(0xFF06B6D4);       // 青
  static const Color success = Color(0xFF10B981);      // 绿
  static const Color warning = Color(0xFFF59E0B);      // 橙
  static const Color danger = Color(0xFFEF4444);       // 红

  // 深色背景层次
  static const Color bgDeep = Color(0xFF0F1117);       // 最底
  static const Color bgSurface = Color(0xFF161A23);    // 卡片
  static const Color bgElevated = Color(0xFF1E2430);   // 悬浮
  static const Color bgHover = Color(0xFF252C3A);      // hover

  // 文字
  static const Color textPrimary = Color(0xFFE6EAF2);
  static const Color textSecondary = Color(0xFF9BA3B4);
  static const Color textMuted = Color(0xFF6B7280);

  // 边框
  static const Color border = Color(0xFF2A3140);

  /// 深色主题
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
      surface: bgSurface,
    ).copyWith(
      primary: primary,
      secondary: accent,
      error: danger,
      surface: bgSurface,
      onSurface: textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bgDeep,
      fontFamily: _defaultFontFamily,
      visualDensity: VisualDensity.compact,

      // 卡片
      cardTheme: CardThemeData(
        color: bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),

      // 分割线
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),

      // 文字
      textTheme: const TextTheme(
        titleLarge: TextStyle(
            fontSize: 18, fontWeight: FontWeight.w600, color: textPrimary),
        titleMedium: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600, color: textPrimary),
        titleSmall: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: textSecondary),
        bodyLarge: TextStyle(fontSize: 14, color: textPrimary),
        bodyMedium: TextStyle(fontSize: 13, color: textPrimary),
        bodySmall: TextStyle(fontSize: 12, color: textSecondary),
        labelLarge: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w500, color: textPrimary),
      ),

      // 按钮
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          textStyle: const TextStyle(fontSize: 13),
        ),
      ),

      // 输入框
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgElevated,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted, fontSize: 13),
      ),

      // 列表
      listTileTheme: const ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
        dense: true,
      ),

      // 滚动条
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(border),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(6),
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: bgElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        textStyle: const TextStyle(color: textPrimary, fontSize: 12),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: bgElevated,
        contentTextStyle: const TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: border),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 默认字体：Windows 用微软雅黑，Linux 用系统默认
  static String? get _defaultFontFamily {
    // Flutter 会 fallback，这里不强制指定，让系统决定
    return null;
  }
}
