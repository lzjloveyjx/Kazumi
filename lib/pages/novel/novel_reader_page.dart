import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/novel_cover_image.dart';
import 'package:kazumi/bean/widget/novel_page_curl.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/novel/novel_reader_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/repositories/novel_shelf_repository.dart';
import 'package:kazumi/services/novel/novel_paginator.dart';
import 'package:kazumi/services/novel/novel_tts_controller.dart';
import 'package:kazumi/services/novel/novel_tts_player.dart';
import 'package:kazumi/services/novel/novel_reader_prefs.dart';
import 'package:kazumi/services/novel/tts_model_manager.dart';

/// 小说阅读页。
///
/// 两种阅读方式，由 [NovelReaderPrefs.pagedMode] 切换：
///   • 翻页（默认）：一章切成若干页，左右滑动/点两侧翻页，进度精确到「第几页」
///   • 滚动：整章长滚动，进度只到「第几章」
///
/// 为什么翻页要自己算：见 NovelPaginator 的注释 —— 必须在「行」这一层切，
/// 否则会出现半行被截断、标点跑到行首这类问题。
///
/// 顶栏/底栏是浮层，点屏幕中间收起，收起后整屏都是正文。
class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.plugin,
    required this.bookTitle,
    required this.roads,
    this.coverUrl = '',
    this.bookKey = '',
    this.initialRoadIndex = 0,
    this.initialChapterIndex = 0,
    this.initialPageIndex = 0,
    this.initialPageAnchor = 0,
  });

  final Plugin plugin;
  final String bookTitle;
  final List<Road> roads;

  /// 书籍身份，用于写阅读进度。空串表示不记录。
  final String coverUrl;
  final String bookKey;

  final int initialRoadIndex;
  final int initialChapterIndex;

  /// 上次读到那一章的第几页，以及那一页的段落锚点。
  final int initialPageIndex;
  final int initialPageAnchor;

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  late final NovelReaderController _controller;
  late final NovelReaderPrefs _prefs;
  late final NovelShelfRepository _shelfRepo;

  /// 滚动模式用的控制器。
  final ScrollController _scroll = ScrollController();

  /// 翻页模式用的控制器。分页结果变了要重建它。
  PageController? _pageController;

  late int _roadIndex = widget.initialRoadIndex;
  late int _chapterIndex = widget.initialChapterIndex;

  /// 顶栏/底栏是否可见。
  bool _barsVisible = true;

  /// 当前章的分页结果。
  List<NovelPage> _pages = const [];

  /// 当前页码（翻页模式）。
  int _pageIndex = 0;

  /// 上一次分页用的参数指纹。参数没变就不重新分页 —— 否则每次 build
  /// （包括收起工具栏）都会重排一遍，卡且会丢当前位置。
  String _layoutKey = '';

  /// 打开新章后，第一次分页完成时要把位置恢复到上次读的地方。
  bool _pendingRestore = false;

  /// 朗读控制器。
  late final NovelTtsPlayer _tts;

  /// 朗读状态（用于刷新按钮与高亮）。
  TtsPlaybackState _ttsState = TtsPlaybackState.idle;

  /// 当前朗读到第几句。
  int _ttsSentenceIndex = 0;

  /// 卷页动画状态。
  ///
  /// null 表示没有正在进行的拖动。否则是 (起拖方向, 0~1 进度)。
  /// 用 drag 而不是点按触发：卷页的手感来自「手指拖着纸角走」，
  /// 点击触发只能做成定时动画，没有跟手的感觉。
  ({bool forward, double progress})? _curl;

  /// 拖动的起点 x，用来判断方向。
  double _dragStartX = 0;

  /// 点按判定用的按下状态。见 [_onPointerUp] 的注释。
  Offset? _downPosition;
  DateTime? _downTime;

  Road get _road => widget.roads[_roadIndex];
  List<String> get _urls => _road.data;
  List<String> get _names => _road.identifier;

  int get _totalChapters =>
      widget.roads.fold<int>(0, (sum, road) => sum + road.data.length);

  @override
  void initState() {
    super.initState();
    _prefs = inject<NovelReaderPrefs>();
    _shelfRepo = inject<NovelShelfRepository>();
    _controller = NovelReaderController(
      plugin: widget.plugin,
      bookTitle: widget.bookTitle,
      contentSelector: widget.plugin.chapterContent,
      dropSelector: widget.plugin.chapterDrop,
    );
    _controller.addListener(_onControllerChanged);
    _tts = NovelTtsPlayer()
      ..onStateChanged = _onTtsStateChanged
      ..onSentenceChanged = _onTtsSentenceChanged
      ..onNotice = _onTtsNotice;

    if (_roadIndex < 0 || _roadIndex >= widget.roads.length) _roadIndex = 0;
    if (_chapterIndex < 0 || _chapterIndex >= _urls.length) _chapterIndex = 0;

    if (_urls.isNotEmpty) {
      _pendingRestore = true;
      _open(_chapterIndex);
    }

    // 阅读时进入沉浸式：隐藏系统状态栏与手势条，整屏都是正文。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    // 退出阅读页必须把系统栏还回去，否则回到列表页会没有状态栏。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _tts.dispose();
    _scroll.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      // 正文换了，旧分页作废。
      _layoutKey = '';
      _pages = const [];
    });
  }

  String _titleAt(int index) {
    if (index < _names.length && _names[index].trim().isNotEmpty) {
      return _names[index];
    }
    return '第 ${index + 1} 章';
  }

  Future<void> _open(int index) async {
    if (index < 0 || index >= _urls.length) return;
    // 换章要先停掉朗读，否则旧章的音频还在播、新的句子又插进来。
    if (_ttsState != TtsPlaybackState.idle) {
      await _tts.stop();
      _ttsSentenceIndex = 0;
    }
    setState(() {
      _chapterIndex = index;
      _pageIndex = 0;
      _pages = const [];
      _layoutKey = '';
    });
    await _controller.openChapter(_urls[index], title: _titleAt(index));
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // 这里**不**记进度：分页还没算出来，_pages 是空的，此时写会把
    // pageIndex/anchor 都写成 0，把刚恢复的位置冲掉。进度改由
    // _restorePosition（分页完成后）和 onPageChanged（翻页时）来写。
  }

  // ── 分页 ────────────────────────────────────────────────────────────────

  /// 按当前排版参数分页。
  ///
  /// 只在参数变化时执行。[maxHeight] 是正文可用高度（已扣掉页边距和工具栏）。
  void _paginateIfNeeded({
    required double width,
    required double height,
    required TextScaler textScaler,
    required bool needRestore,
  }) {
    final style = _prefs.textStyle;
    final key = [
      _chapterIndex,
      _roadIndex,
      width.round(),
      height.round(),
      style.fontSize,
      style.height,
      style.fontFamily,
      _prefs.indent,
      textScaler.scale(100).round(),
    ].join('|');
    if (key == _layoutKey) {
      // 参数没变，但如果这一章刚打开、还没恢复过位置，仍然要恢复。
      if (needRestore && _pages.isNotEmpty) _restorePosition();
      return;
    }
    _layoutKey = key;
    _pages = const NovelPaginator().paginate(
      paragraphs: _controller.paragraphs,
      style: style,
      maxWidth: width,
      maxHeight: height,
      indent: _prefs.indent,
      paragraphSpacing: _prefs.fontSize * 0.72,
      textScaler: textScaler,
    );
    if (needRestore) {
      _restorePosition();
    } else {
      _pageIndex = _pageIndex.clamp(0, (_pages.length - 1).clamp(0, 1 << 30));
    }
  }

  /// 恢复到上次读到的那一页。
  ///
  /// 优先用段落锚点反查：字号变了页数会全变，但「第 N 段在哪一页」是稳的。
  /// 找不到锚点就退回页码（可能因为页数变少而越界，clamp 一下）。
  void _restorePosition() {
    _pendingRestore = false;
    if (_pages.isEmpty) return;
    var target = widget.initialPageIndex;
    final anchor = widget.initialPageAnchor;
    if (anchor > 0) {
      for (var i = _pages.length - 1; i >= 0; i--) {
        if (_pages[i].firstParagraphIndex <= anchor) {
          target = i;
          break;
        }
      }
    }
    target = target.clamp(0, _pages.length - 1);
    _pageIndex = target;
    // PageController 可能还没建好，下一帧再跳。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController?.hasClients ?? false) {
        _pageController!.jumpToPage(target);
      }
      // 位置确定之后再写一次，保证「读到第几页」跟着实际落点走。
      _recordProgress();
    });
  }

  void _recordProgress() {
    if (widget.bookKey.isEmpty) return;
    if (_controller.status != NovelChapterStatus.ready) return;
    final anchor = _pages.isNotEmpty && _pageIndex < _pages.length
        ? _pages[_pageIndex].firstParagraphIndex
        : 0;
    _shelfRepo.recordProgress(
      pluginName: widget.plugin.name,
      bookKey: widget.bookKey,
      title: widget.bookTitle,
      roadIndex: _roadIndex,
      chapterIndex: _chapterIndex,
      chapterUrl: _urls[_chapterIndex],
      chapterTitle: _titleAt(_chapterIndex),
      cover: widget.coverUrl,
      chapterCount: _totalChapters,
      pageIndex: _pageIndex,
      pageAnchor: anchor,
    );
  }

  // ── 交互 ────────────────────────────────────────────────────────────────

  // ── 朗读 ────────────────────────────────────────────────────────────────

  void _onTtsStateChanged(TtsPlaybackState state) {
    if (!mounted) return;
    setState(() => _ttsState = state);
    // 读完最后一句且开了自动续读，跳到下一章继续。
    if (state == TtsPlaybackState.idle &&
        _tts.atEnd &&
        _prefs.ttsAutoNext &&
        _chapterIndex + 1 < _urls.length) {
      _openAndResumeTts(_chapterIndex + 1);
    }
  }

  void _onTtsSentenceChanged(int index) {
    if (!mounted) return;
    setState(() => _ttsSentenceIndex = index);
    // 朗读到的那句可能不在当前页，把页面跟过去 —— 否则「听着听着屏幕不动」
    // 会让人以为卡了。
    _syncPageToSentence(index);
  }

  /// 把当前页跳到包含第 [sentenceIndex] 句的那一页。
  ///
  /// 需要「句子 → 段落 → 页」两层映射：TTS 按句切，分页按段切。做法是先用
  /// 句子在整章文本里的 start 找到它落在哪个段落，再找第一个
  /// firstParagraphIndex 不超过它的页。
  void _syncPageToSentence(int sentenceIndex) {
    if (!_prefs.pagedMode) return;
    if (_pages.isEmpty) return;
    if (sentenceIndex < 0 || sentenceIndex >= _tts.sentences.length) return;

    final charOffset = _tts.sentences[sentenceIndex].start;
    // 各段落起点在整章文本中的累计偏移。
    final paragraphAt = _paragraphIndexAtOffset(charOffset);
    if (paragraphAt < 0) return;

    var target = _pageIndex;
    for (var i = _pages.length - 1; i >= 0; i--) {
      if (_pages[i].firstParagraphIndex <= paragraphAt) {
        target = i;
        break;
      }
    }
    if (target == _pageIndex) return;
    setState(() => _pageIndex = target);
    if (_pageController?.hasClients ?? false) {
      _pageController!.jumpToPage(target);
    }
  }

  /// 字符偏移 → 段落下标。
  int _paragraphIndexAtOffset(int offset) {
    final blocks = NovelPaginator()
        .blocksOf(_controller.paragraphs, indent: _prefs.indent);
    var cursor = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].isImage) continue;
      final len = blocks[i].text.length;
      if (offset < cursor + len) return i;
      cursor += len + 1; // +1 是段落之间的换行
    }
    return -1;
  }

  Future<void> _toggleTts() async {
    if (_ttsState == TtsPlaybackState.speaking) {
      await _tts.pause();
      return;
    }
    if (_ttsState == TtsPlaybackState.paused) {
      await _tts.resume();
      return;
    }
    await _startTts();
  }

  Future<void> _startTts() async {
    _tts.cacheParagraphs(_controller.paragraphs, indent: _prefs.indent);
    await _tts.load(
      paragraphs: _controller.paragraphs,
      indent: _prefs.indent,
      fromSentence: _ttsSentenceIndex,
    );
    _tts.setSpeed(_ttsSpeed);
    // 应用用户选的音色（切换会重置引擎，所以放在 tryUseNeural 之前）。
    await _tts.engine.setVoice(TtsVoice.byId(_prefs.ttsVoiceId));
    // 系统通道的引擎/音色（MultiTTS 等第三方引擎走这里）。
    _tts.setSystemEngine(
      package: _prefs.ttsEnginePackage,
      voice: _prefs.ttsEngineVoice,
    );

    // 优先用本地神经网络；模型没下就先问用户。
    final neural = await _tts.tryUseNeural();
    if (!neural && mounted) {
      final download = await _askDownloadModel();
      if (download == true) {
        final ok = await _downloadModelThenPlay();
        if (ok) return;
      }
    }
    await _tts.play();
  }

  /// 语速倍率。prefs 里存的是系统 TTS 的 rate（0.2~1.0），
  /// 神经网络通道要的是倍率（0.3~3.0），这里做一次映射。
  double get _ttsSpeed => (0.5 + _prefs.ttsRate * 1.5).clamp(0.5, 2.5);

  /// 问用户要不要下载模型。
  Future<bool?> _askDownloadModel() async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('启用神经网络朗读？'),
        content: const Text(
          '语音模型已经打包在应用里（约 31MB），首次使用需要解压到本地，'
          '大约几秒钟，不需要联网。\n\n'
          '启用后音质接近有声书；也可以继续用系统朗读（能听但机械）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('用系统朗读'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('启用'),
          ),
        ],
      ),
    );
  }

  Future<bool> _downloadModelThenPlay() async {
    // 用 SnackBar 显示进度：模型下载是一两分钟的活，不该只有个转圈。
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在解压语音模型…'),
        duration: Duration(minutes: 2),
      ),
    );
    try {
      await _tts.engine.downloadModel(
        onProgress: (p) {
          // 进度百分比挂在 SnackBar 上会刷屏，这里只在整十的时候更新。
          final pct = (p * 100).round();
          if (pct % 10 == 0 && mounted) {
            messenger.showSnackBar(
              SnackBar(
                content: Text('正在解压语音模型… $pct%'),
                duration: const Duration(minutes: 2),
              ),
            );
          }
        },
      );
      messenger.hideCurrentSnackBar();
      final ok = await _tts.tryUseNeural();
      if (ok) {
        await _tts.play(fromSentence: _ttsSentenceIndex);
        return true;
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('模型已解压但加载失败，先用系统朗读')),
      );
      await _tts.play(fromSentence: _ttsSentenceIndex);
      return true;
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('解压失败：$e')),
      );
      await _tts.play(fromSentence: _ttsSentenceIndex);
      return true;
    }
  }

  void _onTtsNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openAndResumeTts(int chapterIndex) async {
    await _open(chapterIndex);
    if (!mounted) return;
    if (_controller.status != NovelChapterStatus.ready) return;
    await _startTts();
  }

  /// 系统 TTS 引擎 / 音色选择面板。
  ///
  /// 为什么要这个：MultiTTS 这类第三方应用把自己注册成**系统 TTS 引擎**，
  /// 装好并导入语音包（微软 Azure / 火山豆包 / sherpa）之后，任何用系统
  /// TTS 的应用都能选它。我们不需要集成它的代码，只要把「选哪个引擎、
  /// 哪个音色」的入口做出来。
  Future<void> _openSystemEngineSheet() async {
    final engines = await _tts.system.listEngines();
    if (!mounted) return;
    final voices = await _tts.system.listVoices();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx2, scrollController) {
          final preset = _prefs.theme;
          return Container(
            decoration: BoxDecoration(
              color: preset.background,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                Text('朗读引擎',
                    style: _prefs.titleStyle.copyWith(fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                  '装了 MultiTTS 之类的第三方引擎，会出现在下面。'
                  '选它之后，系统朗读就用它的音色。',
                  style: TextStyle(fontSize: 12, color: preset.secondary),
                ),
                const SizedBox(height: 12),
                RadioGroup<String>(
                  groupValue: _prefs.ttsEnginePackage,
                  onChanged: (v) {
                    if (v == null) return;
                    _prefs.setTtsEnginePackage(v);
                    _prefs.setTtsEngineVoice('');
                    setState(() {});
                  },
                  child: Column(
                    children: [
                      RadioListTile<String>(
                        value: '',
                        title: const Text('系统默认'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      for (final e in engines)
                        RadioListTile<String>(
                          value: e['package'] ?? '',
                          title: Text(e['name'] ?? ''),
                          subtitle: Text(
                            e['package'] ?? '',
                            style: TextStyle(
                                fontSize: 11, color: preset.secondary),
                          ),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                ),
                if (_prefs.ttsEnginePackage.isNotEmpty) ...[
                  const Divider(height: 32),
                  Text('音色',
                      style: _prefs.titleStyle.copyWith(fontSize: 15)),
                  const SizedBox(height: 8),
                  if (voices.isEmpty)
                    Text(
                      '这个引擎没有报告中文音色。'
                      '可以在系统设置 → 文字转语音里配置。',
                      style: TextStyle(fontSize: 12, color: preset.secondary),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final v in voices)
                          ChoiceChip(
                            label: Text(v['name'] ?? ''),
                            selected:
                                _prefs.ttsEngineVoice == (v['name'] ?? ''),
                            onSelected: (_) {
                              _prefs.setTtsEngineVoice(v['name'] ?? '');
                              setState(() {});
                            },
                          ),
                      ],
                    ),
                ],
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx2).pop();
                  },
                  child: const Text('完成'),
                ),
              ],
            ),
          );
        },
      ),
    );
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

  /// 点按热区：左 1/3 上一页/上一章，右 1/3 下一页/下一章，中间收工具栏。
  void _handleTap(double dx) {
    final width = MediaQuery.of(context).size.width;
    if (dx < width / 3) {
      _previous();
    } else if (dx > width * 2 / 3) {
      _next();
    } else {
      _toggleBars();
    }
  }

  /// 上一页；已经是本页第一页就翻到上一章最后一页。
  void _previous() {
    if (_prefs.pagedMode) {
      if (_pageIndex > 0) {
        _pageController?.previousPage(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (_chapterIndex > 0) {
        _openAtLastPage(_chapterIndex - 1);
        return;
      }
      _toggleBars();
      return;
    }
    // 滚动模式：只能翻章
    if (_chapterIndex > 0) {
      _open(_chapterIndex - 1);
    } else {
      _toggleBars();
    }
  }

  /// 下一页；已经是本页最后一页就翻到下一章第一页。
  void _next() {
    if (_prefs.pagedMode) {
      if (_pageIndex + 1 < _pages.length) {
        _pageController?.nextPage(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (_chapterIndex + 1 < _urls.length) {
        _open(_chapterIndex + 1);
        return;
      }
      _toggleBars();
      return;
    }
    if (_chapterIndex + 1 < _urls.length) {
      _open(_chapterIndex + 1);
    } else {
      _toggleBars();
    }
  }

  /// 打开上一章并跳到最后一页 —— 从后往前读时应该落在章末，不是章首。
  Future<void> _openAtLastPage(int chapterIndex) async {
    await _open(chapterIndex);
    if (!mounted || _pages.isEmpty) return;
    final last = _pages.length - 1;
    setState(() => _pageIndex = last);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController?.hasClients ?? false) {
        _pageController!.jumpToPage(last);
      }
      _recordProgress();
    });
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
      builder: (ctx) => _ReaderSettingsSheet(
        prefs: _prefs,
        onVoiceChanged: (id) {
          _prefs.setTtsVoice(id);
          // 停掉当前朗读，下次点播放就会用新音色（setVoice 会重置引擎）。
          _tts.stop();
        },
        onOpenEngineSheet: _openSystemEngineSheet,
      ),
    );
  }

  /// 图片防盗链用的 Referer：优先取规则里声明的，否则退回站点根。
  String get _imageReferer {
    final referer = widget.plugin.referer.trim();
    return referer.isNotEmpty ? referer : widget.plugin.baseUrl;
  }

  /// 算出这一页需要高亮的字符区间（相对本页第一个块）。
  ///
  /// 返回 (blockIndex, start, end)：blockIndex 是本页内的块下标，start/end
  /// 是该块文本内的偏移。朗读跨段时只能高亮当前句落在这一段的那部分，
  /// 因为一段就是一个 Text，高亮不能跨 Text。
  ({int block, int start, int end})? _highlightForPage(
    int pageNumber,
    NovelPage page,
  ) {
    if (_ttsState == TtsPlaybackState.idle) return null;
    if (pageNumber != _pageIndex) return null;
    if (_ttsSentenceIndex < 0 || _ttsSentenceIndex >= _tts.sentences.length) {
      return null;
    }
    final sentence = _tts.sentences[_ttsSentenceIndex];
    // 句子在整章里的偏移 → 本页第几个块
    final blocks = NovelPaginator()
        .blocksOf(_controller.paragraphs, indent: _prefs.indent);
    var cursor = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].isImage) continue;
      final len = blocks[i].text.length;
      if (sentence.start < cursor + len) {
        // 找到句子所在的块 -> 换算成本页内的块下标
        final inPage = page.blocks.indexWhere(
          (b) => !b.isImage && b.text == blocks[i].text,
        );
        if (inPage < 0) return null;
        return (
          block: inPage,
          start: (sentence.start - cursor).clamp(0, len),
          end: (sentence.end - cursor).clamp(0, len),
        );
      }
      cursor += len + 1;
    }
    return null;
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _prefs,
      builder: (context, _) {
        final preset = _prefs.theme;
        final media = MediaQuery.of(context);
        final topInset =
            _barsVisible ? media.padding.top + kToolbarHeight : media.padding.top;
        final bottomInset =
            _barsVisible ? media.padding.bottom + 64 : media.padding.bottom;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: preset.isDark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: Scaffold(
            backgroundColor: preset.background,
            body: Stack(
              children: [
                Positioned.fill(
                  child: _buildContent(preset, topInset, bottomInset, media),
                ),
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
    MediaQueryData media,
  ) {
    final status = _controller.status;
    if (status == NovelChapterStatus.idle ||
        status == NovelChapterStatus.loading) {
      return Center(child: CircularProgressIndicator(color: preset.secondary));
    }
    if (status == NovelChapterStatus.error) {
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
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 正文可用区域：扣掉左右页边距与上下工具栏。
        final width = constraints.maxWidth - _prefs.margin * 2;
        final height = constraints.maxHeight - topInset - bottomInset - 20;
        if (_prefs.pagedMode) {
          _paginateIfNeeded(
            width: width,
            height: height,
            textScaler: media.textScaler,
            needRestore: _pendingRestore,
          );
          return _buildPaged(preset, width, height);
        }
        return _buildScroll(preset, topInset, bottomInset);
      },
    );
  }

  /// 翻页模式的正文。
  ///
  /// 用「手势拖拽 + 卷页动画」而不是 PageView 的滑动：
  /// PageView 的过渡是整页平移，看着像幻灯片；卷页是把纸角拖起来翻过去，
  /// 手感接近实体书。两者都支持，由 [NovelReaderPrefs] 里的
  /// pageAnimation 决定（卷页 / 平移 / 无动画）。
  Widget _buildPaged(NovelThemePreset preset, double width, double height) {
    if (_pages.isEmpty) {
      return const Center(child: SizedBox.shrink());
    }
    _pageController ??= PageController(initialPage: _pageIndex);

    final curl = _curl;
    if (curl != null && _prefs.pageAnimation == 'curl') {
      // 卷页进行中：叠一层动画
      final forward = curl.forward;
      final outgoingIndex = forward ? _pageIndex : _pageIndex;
      final incomingIndex = forward
          ? (_pageIndex + 1).clamp(0, _pages.length - 1)
          : (_pageIndex - 1).clamp(0, _pages.length - 1);
      return NovelPageCurl(
        progress: curl.progress,
        forward: forward,
        backgroundColor: preset.background,
        outgoing: _pageContent(outgoingIndex, height),
        incoming: _pageContent(incomingIndex, height),
      );
    }

    return GestureDetector(
      // 水平拖动驱动卷页；短距离拖动仍然交给点击热区处理。
      onHorizontalDragStart: _prefs.pageAnimation == 'curl'
          ? (details) {
              _dragStartX = details.localPosition.dx;
            }
          : null,
      onHorizontalDragUpdate: _prefs.pageAnimation == 'curl'
          ? (details) {
              final dx = details.localPosition.dx - _dragStartX;
              final forward = dx < 0;
              final canTurn = forward
                  ? (_pageIndex + 1 < _pages.length ||
                      _chapterIndex + 1 < _urls.length)
                  : (_pageIndex > 0 || _chapterIndex > 0);
              if (!canTurn) {
                setState(() => _curl = null);
                return;
              }
              final progress = (dx.abs() / width).clamp(0.0, 1.0);
              setState(() => _curl = (forward: forward, progress: progress));
            }
          : null,
      onHorizontalDragEnd: _prefs.pageAnimation == 'curl'
          ? (details) {
              final curl = _curl;
              if (curl == null) return;
              // 拖过 30% 或快速甩动就完成翻页
              final velocity = details.velocity.pixelsPerSecond.dx;
              final flung = curl.forward ? velocity < -300 : velocity > 300;
              if (curl.progress > 0.3 || flung) {
                setState(() => _curl = null);
                if (curl.forward) {
                  _next();
                } else {
                  _previous();
                }
              } else {
                // 没翻过去：回弹
                setState(() => _curl = null);
              }
            }
          : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        child: PageView.builder(
          controller: _pageController,
          // 卷页模式下禁用 PageView 自带的滑动，避免两套动画打架
          physics: _prefs.pageAnimation == 'curl'
              ? const NeverScrollableScrollPhysics()
              : null,
          itemCount: _pages.length,
          onPageChanged: (index) {
            setState(() => _pageIndex = index);
            _recordProgress();
          },
          itemBuilder: (context, index) => _pageContent(index, height),
        ),
      ),
    );
  }

  /// 单页内容（卷页与 PageView 共用）。
  Widget _pageContent(int index, double height) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _prefs.margin,
        _barsVisible ? kToolbarHeight + 8 : 8,
        _prefs.margin,
        _barsVisible ? 64 : 8,
      ),
      child: _PageView(
        page: _pages[index],
        prefs: _prefs,
        referer: _imageReferer,
        maxHeight: height,
        highlight: _highlightForPage(index, _pages[index]),
      ),
    );
  }

  /// 滚动模式的正文（原长滚动实现）。
  Widget _buildScroll(
    NovelThemePreset preset,
    double topInset,
    double bottomInset,
  ) {
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
            for (final block in NovelPaginator()
                .blocksOf(_controller.paragraphs, indent: _prefs.indent))
              Padding(
                padding: EdgeInsets.only(bottom: _prefs.fontSize * 0.72),
                child: _BlockView(
                  block: block,
                  prefs: _prefs,
                  referer: _imageReferer,
                ),
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
    final paged = _prefs.pagedMode;
    final pageCount = _pages.isEmpty ? 1 : _pages.length;
    final progressLabel = paged
        ? '${_pageIndex + 1} / $pageCount 页 · 第 ${_chapterIndex + 1}/${_urls.length} 章'
        : '第 ${_chapterIndex + 1}/${_urls.length} 章';
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
                    onPressed: _previous,
                    icon: Icon(Icons.chevron_left, color: preset.text),
                    tooltip: paged ? '上一页' : '上一章',
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _titleAt(_chapterIndex),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: _prefs.captionStyle,
                        ),
                        Text(
                          progressLabel,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          style: _prefs.captionStyle.copyWith(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _next,
                    icon: Icon(Icons.chevron_right, color: preset.text),
                    tooltip: paged ? '下一页' : '下一章',
                  ),
                  IconButton(
                    tooltip: _ttsState == TtsPlaybackState.speaking
                        ? '暂停朗读'
                        : (_ttsState == TtsPlaybackState.paused
                            ? '继续朗读'
                            : '朗读'),
                    onPressed: _controller.status == NovelChapterStatus.ready
                        ? _toggleTts
                        : null,
                    icon: Icon(
                      _ttsState == TtsPlaybackState.speaking
                          ? Icons.pause_circle_filled
                          : Icons.headphones,
                      color: _ttsState == TtsPlaybackState.speaking
                          ? Theme.of(context).colorScheme.primary
                          : preset.text,
                    ),
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

/// 一页的内容。
///
/// 用 NeverScrollable 的 SingleChildScrollView 包一层，而不是裸 Column：
/// 分页是按测量高度算的，但字体渲染有极小误差，万一算多了半像素，裸 Column
/// 会抛 overflow。包起来之后最多是「最后一行被裁掉一点」，不影响阅读，
/// 也不会在日志里刷一堆异常。
class _PageView extends StatelessWidget {
  const _PageView({
    required this.page,
    required this.prefs,
    required this.referer,
    required this.maxHeight,
    this.highlight,
  });

  final NovelPage page;
  final NovelReaderPrefs prefs;
  final String referer;
  final double maxHeight;

  /// 朗读高亮：(页内块下标, 块内起, 块内止)。
  final ({int block, int start, int end})? highlight;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < page.blocks.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: prefs.fontSize * 0.72),
                child: _BlockView(
                  block: page.blocks[i],
                  prefs: prefs,
                  referer: referer,
                  highlight:
                      highlight != null && highlight!.block == i ? highlight : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView({
    required this.block,
    required this.prefs,
    required this.referer,
    this.highlight,
  });

  final NovelBlock block;
  final NovelReaderPrefs prefs;
  final String referer;
  final ({int block, int start, int end})? highlight;

  @override
  Widget build(BuildContext context) {
    final url = block.imageUrl;
    if (url != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: NovelCoverImage(url: url, referer: referer, fit: BoxFit.contain),
      );
    }

    final h = highlight;
    if (h == null) {
      return Text(block.text, style: prefs.textStyle);
    }

    // 用 TextSpan 给正在朗读的那一段上底色，而不是整段换样式：
    // 高亮范围是一句话，通常只占段落的一部分，整段变色会让人分不清读到哪。
    final text = block.text;
    final start = h.start.clamp(0, text.length);
    final end = h.end.clamp(start, text.length);
    if (start == end) {
      return Text(text, style: prefs.textStyle);
    }
    final mark = NovelHighlightColors.of(context);
    return Text.rich(
      TextSpan(
        style: prefs.textStyle,
        children: [
          if (start > 0) TextSpan(text: text.substring(0, start)),
          TextSpan(
            text: text.substring(start, end),
            style: TextStyle(backgroundColor: mark),
          ),
          if (end < text.length) TextSpan(text: text.substring(end)),
        ],
      ),
    );
  }
}

/// 朗读高亮用的底色。
///
/// 单独抽出来是因为它要跟阅读背景搭配：米黄底上用淡蓝，夜间用低饱和的
/// 暗蓝 —— 一个固定的 colorScheme.primary 在浅色和深色阅读主题下总有一边
/// 看不清。用带 alpha 的叠色，文字本身颜色不变，所以对比度不会掉。
class NovelHighlightColors {
  const NovelHighlightColors._();

  static Color of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0x553A6EA5)
        : const Color(0x331E88E5);
  }
}

/// 阅读设置面板。
class _ReaderSettingsSheet extends StatelessWidget {
  const _ReaderSettingsSheet({
    required this.prefs,
    required this.onVoiceChanged,
    required this.onOpenEngineSheet,
  });

  final NovelReaderPrefs prefs;

  /// 切换音色：设置面板只负责改偏好，真正重启朗读引擎要由阅读页做
  /// （那里才有 _tts）。
  final void Function(String voiceId) onVoiceChanged;

  /// 打开系统引擎选择面板（同样只有阅读页能访问 _tts）。
  final VoidCallback onOpenEngineSheet;

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
                  Row(
                    children: [
                      SizedBox(
                        width: 56,
                        child: Text(
                          '方式',
                          style:
                              TextStyle(fontSize: 14, color: preset.secondary),
                        ),
                      ),
                      Expanded(
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('翻页'),
                              icon: Icon(Icons.auto_stories, size: 18),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('滚动'),
                              icon: Icon(Icons.swap_vert, size: 18),
                            ),
                          ],
                          selected: {prefs.pagedMode},
                          onSelectionChanged: (value) =>
                              prefs.setPagedMode(value.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _LabeledRow(
                    preset: preset,
                    label: '翻页动画',
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final option in const [
                          ('curl', '卷页'),
                          ('slide', '平移'),
                          ('none', '无'),
                        ])
                          ChoiceChip(
                            label: Text(option.$2),
                            selected: prefs.pageAnimation == option.$1,
                            onSelected: (_) =>
                                prefs.setPageAnimation(option.$1),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
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
                    title: Text(
                      '首行缩进',
                      style: prefs.captionStyle.copyWith(
                        fontSize: 14,
                        color: preset.text,
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  Text(
                    '朗读',
                    style: TextStyle(fontSize: 14, color: preset.secondary),
                  ),
                  const SizedBox(height: 4),
                  _LabeledRow(
                    preset: preset,
                    label: '音色',
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final v in TtsVoice.values)
                          ChoiceChip(
                            label: Text(v.label),
                            selected: prefs.ttsVoiceId == v.id,
                            onSelected: (_) => onVoiceChanged(v.id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _LabeledRow(
                    preset: preset,
                    label: '系统朗读引擎',
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        onOpenEngineSheet();
                      },
                      icon: const Icon(Icons.settings_voice, size: 18),
                      label: Text(
                        _prefs.ttsEnginePackage.isEmpty
                            ? '系统默认'
                            : _prefs.ttsEnginePackage,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  _SliderRow(
                    preset: preset,
                    label: '语速',
                    value: prefs.ttsRate,
                    min: 0.2,
                    max: 1.0,
                    divisions: 16,
                    display: prefs.ttsRate.toStringAsFixed(1),
                    onChanged: prefs.setTtsRate,
                  ),
                  _SliderRow(
                    preset: preset,
                    label: '音调',
                    value: prefs.ttsPitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    display: prefs.ttsPitch.toStringAsFixed(1),
                    onChanged: prefs.setTtsPitch,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: prefs.ttsAutoNext,
                    onChanged: prefs.setTtsAutoNext,
                    title: Text(
                      '读完自动下一章',
                      style: prefs.captionStyle.copyWith(
                        fontSize: 14,
                        color: preset.text,
                      ),
                    ),
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
