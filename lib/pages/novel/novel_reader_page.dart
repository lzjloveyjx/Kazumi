import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/novel/novel_reader_controller.dart';
import 'package:kazumi/plugins/plugins.dart';

/// 小说阅读页。
///
/// 输入：一条规则（[Plugin]）+ 书名 + 该书的章节线路（[Road]，规则引擎
/// 已经解析好的 chapterRoads/chapterResult 结果）。
///
/// 设计取舍：
///   • 不做分页，直接长滚动 —— 中文网文一章动辄几千字，分页反而更难读
///   • 字号/行距给到设置里的「阅读偏好」上限，先固定，后面接偏好
///   • 上下章按钮固定在底部，避免每章都滚到底才能翻页
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
  final ScrollController _scroll = ScrollController();
  int _roadIndex = 0;
  int _chapterIndex = 0;

  Road get _road => widget.roads[_roadIndex];
  List<String> get _urls => _road.data;
  List<String> get _names => _road.identifier;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _controller.status;
    return Scaffold(
      appBar: SysAppBar(
        title: Text(
          widget.bookTitle,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.roads.length > 1)
            IconButton(
              tooltip: '切换线路',
              onPressed: _pickRoad,
              icon: const Icon(Icons.alt_route),
            ),
          IconButton(
            tooltip: '目录',
            onPressed: _urls.isEmpty ? null : _pickChapter,
            icon: const Icon(Icons.list),
          ),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        canPrev: _chapterIndex > 0,
        canNext: _chapterIndex + 1 < _urls.length,
        label: _titleAt(_chapterIndex),
        onPrev: () => _open(_chapterIndex - 1),
        onNext: () => _open(_chapterIndex + 1),
      ),
      body: switch (status) {
        NovelChapterStatus.idle ||
        NovelChapterStatus.loading =>
          const Center(child: LoadingIndicator()),
        NovelChapterStatus.error => GeneralEmptyState(
            icon: Icons.menu_book_outlined,
            title: _controller.error.isEmpty ? '这一章读不出来' : _controller.error,
            actions: [
              FilledButton(
                onPressed: () => _open(_chapterIndex),
                child: const Text('重试'),
              ),
            ],
          ),
        NovelChapterStatus.ready => SelectionArea(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Text(
                  _controller.chapterTitle.isEmpty
                      ? _titleAt(_chapterIndex)
                      : _controller.chapterTitle,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                for (final p in _controller.paragraphs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      p,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        height: 1.8,
                        fontSize: 17,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      },
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.canPrev,
    required this.canNext,
    required this.label,
    required this.onPrev,
    required this.onNext,
  });

  final bool canPrev;
  final bool canNext;
  final String label;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            IconButton(
              onPressed: canPrev ? onPrev : null,
              icon: const Icon(Icons.chevron_left),
              tooltip: '上一章',
            ),
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            IconButton(
              onPressed: canNext ? onNext : null,
              icon: const Icon(Icons.chevron_right),
              tooltip: '下一章',
            ),
          ],
        ),
      ),
    );
  }
}
