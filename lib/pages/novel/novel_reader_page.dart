import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/novel/novel_reader_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/novel/novel_reader_prefs.dart';

/// 小说阅读页。
///
/// 输入：一条规则（[Plugin]）+ 书名 + 该书的章节线路（[Road]，规则引擎
/// 已经解析好的 chapterRoads/chapterResult 结果）。
///
/// 设计取舍：
///   • 不做分页，直接长滚动 —— 中文网文一章动辄几千字，分页反而更难读
///   • 顶栏/底栏是**浮层**，不占布局：点屏幕中间可以收起来，收起来之后
///     整屏都是正文，这才是「看书」而不是「看网页」
///   • 左右两侧留了点按热区（左 1/3 上一章、右 1/3 下一章），和主流阅读器
///     一致，省得每次都去够底栏
///   • 字号/行距/边距/字体/背景全部走 [NovelReaderPrefs]，改完立刻生效
class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.plugin,
    required this.bookTitle,
    required this.roads,
  });

  final Plugin plugin;
  final String bookTitle;
  final List<Road> roads;

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  late final NovelReaderController _controller;
  late final NovelReaderPrefs _prefs;
  final ScrollController _scroll = ScrollController();
  int _roadIndex = 0;
  int _chapterIndex = 0;

  /// 顶栏/底栏是否可见。
  bool _barsVisible = true;

  /// 点按判定用的按下状态。
  ///
  /// 为什么不用 GestureDetector.onTapUp：正文外面套了 SelectionArea，
  /// 它自己也会抢 tap（用来取消选区），而手势竞技场里**更深的 widget 先赢**，
  /// 外层 GestureDetector 的 onTapUp 永远等不到。Listener 不进竞技场、
  /// 只是旁听指针事件，所以这里自己判「短按且几乎没移动」。
  Offset? _downPosition;
  DateTime? _downTime;

  Road get _road => widget.roads[_roadIndex];
  List<String> get _urls => _road.data;
  List<String> get _names => _road.identifier;

  @override
  void initState() {
    super.initState();
    _prefs = inject<NovelReaderPrefs>();
    _controller = NovelReaderController(
      plugin: widget.plugin,
      bookTitle: widget.bookTitle,
      contentSelector: widget.plugin.chapterContent,
    );
    _controller.addListener(_onControllerChanged);
    if (_urls.isNotEmpty) {
      _open(0);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  String _titleAt(int index) {
    if (index < _names.length && _names[index].trim().isNotEmpty) {
      return _names[index];
    }
    return '第 ${index + 1} 章';
  }

  Future<void> _open(int index) async {
    if (index < 0 || index >= _urls.length) return;
    setState(() => _chapterIndex = index);
    await _controller.openChapter(_urls[index], title: _titleAt(index));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _toggleBars() {
    setState(() => _barsVisible = !_barsVisible);
  }

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent event) {
    final start = _downPosition;
    final time = _downTime;
    _downPosition = null;
    _downTime = null;
    if (start == null || time == null) return;
    // 滑动（翻页/滚动）和长按（选字）都不算点按
    if ((event.position - start).distance > 12) return;
    if (DateTime.now().difference(time) > Duration(milliseconds: 350)) return;
    _handleTap(event.localPosition.dx);
  }

  /// 点按热区：左 1/3 上一章，右 1/3 下一章，中间收起/展开工具栏。
  void _handleTap(double dx) {
    final width = MediaQuery.of(context).size.width;
    if (dx < width / 3) {
      if (_chapterIndex > 0) {
        _open(_chapterIndex - 1);
      } else {
        _toggleBars();
      }
      return;
    }
    if (dx > width * 2 / 3) {
      if (_chapterIndex + 1 < _urls.length) {
        _open(_chapterIndex + 1);
      } else {
        _toggleBars();
      }
      return;
    }
    _toggleBars();
  }

  Future<void> _pickRoad() async {
    if (widget.roads.length < 2) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < widget.roads.length; i++)
              ListTile(
                title: Text('线路 ${i + 1}（${widget.roads[i].data.length} 章）'),
                selected: i == _roadIndex,
                onTap: () => Navigator.of(ctx).pop(i),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == _roadIndex) return;
    setState(() {
      _roadIndex = picked;
      _chapterIndex = 0;
    });
    await _open(0);
  }

  Future<void> _pickChapter() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx2, scrollController) => ListView.builder(
          controller: scrollController,
          itemCount: _urls.length,
          itemBuilder: (c, i) => ListTile(
            dense: true,
            selected: i == _chapterIndex,
            title: Text(_titleAt(i)),
            onTap: () => Navigator.of(ctx).pop(i),
          ),
        ),
      ),
    );
    if (picked == null) return;
    await _open(picked);
  }

  Future<void> _openReaderSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ReaderSettingsSheet(prefs: _prefs),
    );
  }

  /// 抽取器把 <img> 折成了 `[图片] <url>` 一行文本 —— 这样正文仍是纯文本、
  /// 便于段落切分与选择复制。这里再把它认出来还原成图片控件。
  static const String _imageMarker = '[图片] ';

  /// 图片防盗链用的 Referer：优先取规则里声明的，否则退回站点根。
  String get _imageReferer {
    final referer = widget.plugin.referer.trim();
    if (referer.isNotEmpty) return referer;
    return widget.plugin.baseUrl;
  }

  Widget _paragraph(String text, NovelThemePreset preset) {
    if (!text.startsWith(_imageMarker)) {
      // 首行缩进用两个全角空格，比 TextIndent 更贴近中文排版习惯：
      // 段落换行后缩进自然对齐，也不会在图片段落上多出一截空白。
      final body = _prefs.indent ? '\u3000\u3000$text' : text;
      return Text(body, style: _prefs.textStyle);
    }
    final url = text.substring(_imageMarker.length).trim();
    if (!url.startsWith('http')) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          fit: BoxFit.contain,
          headers: {'referer': _imageReferer},
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: preset.secondary,
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('（插图加载失败）$url', style: _prefs.captionStyle),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _prefs,
      builder: (context, _) {
        final preset = _prefs.theme;
        final media = MediaQuery.of(context);
        final topInset = media.padding.top + kToolbarHeight;
        final bottomInset = media.padding.bottom + 64;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: preset.isDark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: Scaffold(
            backgroundColor: preset.background,
            body: Stack(
              children: [
                Positioned.fill(child: _buildContent(preset, topInset, bottomInset)),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _buildTopBar(preset, media.padding.top),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildBottomBar(preset, media.padding.bottom),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(
    NovelThemePreset preset,
    double topInset,
    double bottomInset,
  ) {
    final status = _controller.status;
    switch (status) {
      case NovelChapterStatus.idle:
      case NovelChapterStatus.loading:
        return Center(
          child: CircularProgressIndicator(color: preset.secondary),
        );
      case NovelChapterStatus.error:
        return GeneralEmptyState(
          icon: Icons.menu_book_outlined,
          title: _controller.error.isEmpty ? '这一章读不出来' : _controller.error,
          actions: [
            FilledButton(
              onPressed: () => _open(_chapterIndex),
              child: const Text('重试'),
            ),
          ],
        );
      case NovelChapterStatus.ready:
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          child: SelectionArea(
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                _prefs.margin,
                topInset + 20,
                _prefs.margin,
                bottomInset + 24,
              ),
              children: [
                Text(
                  _controller.chapterTitle.isEmpty
                      ? _titleAt(_chapterIndex)
                      : _controller.chapterTitle,
                  style: _prefs.titleStyle,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_chapterIndex + 1} / ${_urls.length}',
                  style: _prefs.captionStyle,
                ),
                const SizedBox(height: 20),
                for (final p in _controller.paragraphs)
                  Padding(
                    padding: EdgeInsets.only(bottom: _prefs.fontSize * 0.72),
                    child: _paragraph(p, preset),
                  ),
                const SizedBox(height: 12),
                Text(
                  _chapterIndex + 1 < _urls.length
                      ? '（本章完，点击屏幕右侧看下一章）'
                      : '（全书完）',
                  textAlign: TextAlign.center,
                  style: _prefs.captionStyle,
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _buildTopBar(NovelThemePreset preset, double statusBarHeight) {
    return IgnorePointer(
      ignoring: !_barsVisible,
      child: AnimatedSlide(
        offset: _barsVisible ? Offset.zero : const Offset(0, -1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _barsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: Container(
            color: preset.background.withValues(alpha: 0.97),
            padding: EdgeInsets.only(top: statusBarHeight),
            child: SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.arrow_back, color: preset.text),
                    tooltip: '返回',
                  ),
                  Expanded(
                    child: Text(
                      widget.bookTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _prefs.captionStyle.copyWith(
                        fontSize: 15,
                        color: preset.text,
                      ),
                    ),
                  ),
                  if (widget.roads.length > 1)
                    IconButton(
                      tooltip: '切换线路',
                      onPressed: _pickRoad,
                      icon: Icon(Icons.alt_route, color: preset.text),
                    ),
                  IconButton(
                    tooltip: '目录',
                    onPressed: _urls.isEmpty ? null : _pickChapter,
                    icon: Icon(Icons.list, color: preset.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(NovelThemePreset preset, double bottomInset) {
    return IgnorePointer(
      ignoring: !_barsVisible,
      child: AnimatedSlide(
        offset: _barsVisible ? Offset.zero : const Offset(0, 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _barsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: Container(
            color: preset.background.withValues(alpha: 0.97),
            padding: EdgeInsets.only(bottom: bottomInset),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _chapterIndex > 0
                        ? () => _open(_chapterIndex - 1)
                        : null,
                    icon: Icon(
                      Icons.chevron_left,
                      color: _chapterIndex > 0
                          ? preset.text
                          : preset.secondary.withValues(alpha: 0.4),
                    ),
                    tooltip: '上一章',
                  ),
                  Expanded(
                    child: Text(
                      _titleAt(_chapterIndex),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _prefs.captionStyle,
                    ),
                  ),
                  IconButton(
                    onPressed: _chapterIndex + 1 < _urls.length
                        ? () => _open(_chapterIndex + 1)
                        : null,
                    icon: Icon(
                      Icons.chevron_right,
                      color: _chapterIndex + 1 < _urls.length
                          ? preset.text
                          : preset.secondary.withValues(alpha: 0.4),
                    ),
                    tooltip: '下一章',
                  ),
                  IconButton(
                    tooltip: '阅读设置',
                    onPressed: _openReaderSettings,
                    icon: Icon(Icons.text_fields, color: preset.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读设置面板：字号、行距、边距、字体、背景、首行缩进。
///
/// 全部改动即时生效 —— 面板是半屏浮层，上半部分还露着正文，能直接看到效果。
/// 不做「确定/取消」，因为这里的每一项都是可逆的、且没有副作用。
class _ReaderSettingsSheet extends StatelessWidget {
  const _ReaderSettingsSheet({required this.prefs});

  final NovelReaderPrefs prefs;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) {
        final preset = prefs.theme;
        return Container(
          decoration: BoxDecoration(
            color: preset.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: preset.secondary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '阅读设置',
                        style: prefs.titleStyle.copyWith(fontSize: 16),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: prefs.resetAppearance,
                        child: Text(
                          '恢复默认',
                          style: TextStyle(color: preset.secondary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _StepperRow(
                    preset: preset,
                    label: '字号',
                    value: prefs.fontSize.round().toString(),
                    onMinus: () => prefs.setFontSize(prefs.fontSize - 1),
                    onPlus: () => prefs.setFontSize(prefs.fontSize + 1),
                  ),
                  _SliderRow(
                    preset: preset,
                    label: '行距',
                    value: prefs.lineHeight,
                    min: 1.2,
                    max: 2.6,
                    divisions: 14,
                    display: prefs.lineHeight.toStringAsFixed(1),
                    onChanged: prefs.setLineHeight,
                  ),
                  _SliderRow(
                    preset: preset,
                    label: '边距',
                    value: prefs.margin,
                    min: 0,
                    max: 48,
                    divisions: 24,
                    display: prefs.margin.round().toString(),
                    onChanged: prefs.setMargin,
                  ),
                  const SizedBox(height: 8),
                  _LabeledRow(
                    preset: preset,
                    label: '字体',
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final option in NovelFontFamilyOption.values)
                          ChoiceChip(
                            label: Text(option.label),
                            selected: prefs.fontFamily.id == option.id,
                            onSelected: (_) => prefs.setFontFamily(option.id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _LabeledRow(
                    preset: preset,
                    label: '背景',
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final option in NovelThemePreset.values)
                          _ThemeSwatch(
                            preset: option,
                            selected: preset.id == option.id,
                            onTap: () => prefs.setTheme(option.id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: prefs.indent,
                    onChanged: prefs.setIndent,
                    title: Text('首行缩进', style: prefs.captionStyle.copyWith(
                      fontSize: 14,
                      color: preset.text,
                    )),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.preset,
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  final NovelThemePreset preset;
  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 14, color: preset.secondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: preset.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: onMinus,
          icon: Icon(Icons.remove_circle_outline, color: preset.text),
        ),
        IconButton(
          onPressed: onPlus,
          icon: Icon(Icons.add_circle_outline, color: preset.text),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.preset,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final NovelThemePreset preset;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 14, color: preset.secondary),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 14, color: preset.text),
          ),
        ),
      ],
    );
  }
}

class _LabeledRow extends StatelessWidget {
  const _LabeledRow({
    required this.preset,
    required this.label,
    required this.child,
  });

  final NovelThemePreset preset;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 14, color: preset.secondary)),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// 背景色块。选中态用一圈描边而不是勾选图标 —— 勾选图标会盖住颜色本身。
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final NovelThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: preset.background,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : preset.secondary.withValues(alpha: 0.35),
                width: selected ? 2.5 : 1,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '文',
              style: TextStyle(color: preset.text, fontSize: 15),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            preset.label,
            style: TextStyle(fontSize: 11, color: preset.secondary),
          ),
        ],
      ),
    );
  }
}
