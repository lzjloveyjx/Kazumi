import 'package:flutter/material.dart';

import 'package:kazumi/services/storage/storage.dart';

/// 阅读器的背景配色。
///
/// 为什么不用主题色（colorScheme）推导：阅读页要的是**低刺激、长时间不累**
/// 的纸面效果，而应用主题是给卡片/按钮设计的，它的 surface 在深色模式下
/// 是灰蓝而不是纯黑，长时间读会发灰。所以这里给一组固定的纸面预设，
/// 每套都是「底色 + 正文色」成对出现，避免文字对比度靠猜。
class NovelThemePreset {
  const NovelThemePreset({
    required this.id,
    required this.label,
    required this.background,
    required this.text,
    required this.secondary,
    required this.isDark,
  });

  final String id;
  final String label;
  final Color background;

  /// 正文颜色。
  final Color text;

  /// 章节名、页码、分割线这类次要文字。
  final Color secondary;

  final bool isDark;

  static const NovelThemePreset paper = NovelThemePreset(
    id: 'paper',
    label: '米黄',
    background: Color(0xFFF6F0E2),
    text: Color(0xFF2E2A24),
    secondary: Color(0xFF8A8172),
    isDark: false,
  );

  static const NovelThemePreset white = NovelThemePreset(
    id: 'white',
    label: '白纸',
    background: Color(0xFFFFFFFF),
    text: Color(0xFF1A1A1A),
    secondary: Color(0xFF8C8C8C),
    isDark: false,
  );

  static const NovelThemePreset green = NovelThemePreset(
    id: 'green',
    label: '护眼',
    background: Color(0xFFCCE8CF),
    text: Color(0xFF1F3325),
    secondary: Color(0xFF5E7A66),
    isDark: false,
  );

  static const NovelThemePreset night = NovelThemePreset(
    id: 'night',
    label: '夜间',
    background: Color(0xFF1B1B1B),
    text: Color(0xFFC8C8C8),
    secondary: Color(0xFF7A7A7A),
    isDark: true,
  );

  static const NovelThemePreset black = NovelThemePreset(
    id: 'black',
    label: '纯黑',
    background: Color(0xFF000000),
    text: Color(0xFFAFAFAF),
    secondary: Color(0xFF6A6A6A),
    isDark: true,
  );

  static const List<NovelThemePreset> values = [
    paper,
    white,
    green,
    night,
    black,
  ];

  static NovelThemePreset byId(String id) {
    for (final preset in values) {
      if (preset.id == id) return preset;
    }
    return paper;
  }
}

/// 正文字体族。
///
/// 值直接用 Flutter 的通用族名，交给系统去映射：Android 上 'serif' 落到
/// Noto Serif CJK（宋体味，长篇最舒服），'sans-serif' 落到 Noto Sans CJK。
/// 不写死具体字体文件，是因为中文衬线字重全的字库动辄十几 MB，
/// 为了一个阅读页把包撑大不值得。
class NovelFontFamilyOption {
  const NovelFontFamilyOption({
    required this.id,
    required this.label,
    required this.family,
  });

  final String id;
  final String label;

  /// null = 跟随应用字体（Kazumi 自带 MI Sans）。
  final String? family;

  static const NovelFontFamilyOption system = NovelFontFamilyOption(
    id: 'system',
    label: '系统',
    family: null,
  );
  static const NovelFontFamilyOption serif = NovelFontFamilyOption(
    id: 'serif',
    label: '宋体',
    family: 'serif',
  );
  static const NovelFontFamilyOption sans = NovelFontFamilyOption(
    id: 'sans',
    label: '黑体',
    family: 'sans-serif',
  );

  static const List<NovelFontFamilyOption> values = [system, serif, sans];

  static NovelFontFamilyOption byId(String id) {
    for (final option in values) {
      if (option.id == id) return option;
    }
    return system;
  }
}

/// 阅读器偏好：字号、行距、边距、字体、背景、首行缩进。
///
/// 做成 ChangeNotifier 单例（注册在 coreModule）：阅读页和设置页看的是
/// 同一份状态，改完立刻两边都变，不用各自维护副本。
///
/// 读写全部走 GStorage 的 setting box（同步读、异步写）。写失败不抛错 ——
/// 一次偏好没存上不该让阅读中断。
class NovelReaderPrefs extends ChangeNotifier {
  NovelReaderPrefs() {
    _read();
  }

  double _fontSize = 18;
  double _lineHeight = 1.8;
  double _margin = 20;
  String _fontFamilyId = 'system';
  String _themeId = 'paper';
  bool _indent = true;

  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  double get margin => _margin;
  bool get indent => _indent;
  NovelFontFamilyOption get fontFamily =>
      NovelFontFamilyOption.byId(_fontFamilyId);
  NovelThemePreset get theme => NovelThemePreset.byId(_themeId);

  /// 正文样式。字重刻意用 w400 而不是主题的 bodyLarge —— 中文正文加粗一点
  /// 就显脏，长读会累。
  TextStyle get textStyle => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        color: theme.text,
        fontWeight: FontWeight.w400,
        fontFamily: fontFamily.family,
      );

  TextStyle get titleStyle => TextStyle(
        fontSize: _fontSize + 3,
        height: 1.4,
        color: theme.text,
        fontWeight: FontWeight.w600,
        fontFamily: fontFamily.family,
      );

  TextStyle get captionStyle => TextStyle(
        fontSize: (_fontSize - 4).clamp(10, 20).toDouble(),
        color: theme.secondary,
        fontFamily: fontFamily.family,
      );

  void _read() {
    try {
      _fontSize = GStorage.getSetting(SettingsKeys.novelFontSize);
      _lineHeight = GStorage.getSetting(SettingsKeys.novelLineHeight);
      _margin = GStorage.getSetting(SettingsKeys.novelMargin);
      _fontFamilyId = GStorage.getSetting(SettingsKeys.novelFontFamily);
      _themeId = GStorage.getSetting(SettingsKeys.novelTheme);
      _indent = GStorage.getSetting(SettingsKeys.novelIndent);
    } catch (_) {
      // box 还没打开（极早期调用）时用默认值，不阻断
    }
  }

  void setFontSize(double value) {
    final next = value.clamp(12.0, 34.0).toDouble();
    if (next == _fontSize) return;
    _fontSize = next;
    GStorage.putSetting(SettingsKeys.novelFontSize, next);
    notifyListeners();
  }

  void setLineHeight(double value) {
    final next = value.clamp(1.2, 2.6).toDouble();
    if (next == _lineHeight) return;
    _lineHeight = next;
    GStorage.putSetting(SettingsKeys.novelLineHeight, next);
    notifyListeners();
  }

  void setMargin(double value) {
    final next = value.clamp(0.0, 48.0).toDouble();
    if (next == _margin) return;
    _margin = next;
    GStorage.putSetting(SettingsKeys.novelMargin, next);
    notifyListeners();
  }

  void setFontFamily(String id) {
    if (id == _fontFamilyId) return;
    _fontFamilyId = id;
    GStorage.putSetting(SettingsKeys.novelFontFamily, id);
    notifyListeners();
  }

  void setTheme(String id) {
    if (id == _themeId) return;
    _themeId = id;
    GStorage.putSetting(SettingsKeys.novelTheme, id);
    notifyListeners();
  }

  void setIndent(bool value) {
    if (value == _indent) return;
    _indent = value;
    GStorage.putSetting(SettingsKeys.novelIndent, value);
    notifyListeners();
  }

  /// 恢复默认外观（不含阅读进度）。
  void resetAppearance() {
    _fontSize = 18;
    _lineHeight = 1.8;
    _margin = 20;
    _fontFamilyId = 'system';
    _themeId = 'paper';
    _indent = true;
    GStorage.putSetting(SettingsKeys.novelFontSize, _fontSize);
    GStorage.putSetting(SettingsKeys.novelLineHeight, _lineHeight);
    GStorage.putSetting(SettingsKeys.novelMargin, _margin);
    GStorage.putSetting(SettingsKeys.novelFontFamily, _fontFamilyId);
    GStorage.putSetting(SettingsKeys.novelTheme, _themeId);
    GStorage.putSetting(SettingsKeys.novelIndent, _indent);
    notifyListeners();
  }
}
