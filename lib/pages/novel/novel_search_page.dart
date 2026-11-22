import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/novel/novel_reader_page.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/captcha_flow.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show CaptchaRequiredException;

/// 小说搜索页。
///
/// 只列出 supportsNovel 为真的规则（type == novel，或规则里写了
/// chapterContent）。搜索本身完全复用 Kazumi 的 Plugin.queryBangumi，
/// 也就是现有规则引擎 —— 这里没有任何新的抓取逻辑。
class NovelSearchPage extends StatefulWidget {
  const NovelSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  State<NovelSearchPage> createState() => _NovelSearchPageState();
}

class _NovelSearchPageState extends State<NovelSearchPage> {
  final TextEditingController _input = TextEditingController();
  final List<Plugin> _sources = <Plugin>[];
  Plugin? _source;

  bool _searching = false;
  String _error = '';
  List<SearchItem> _results = const <SearchItem>[];

  /// 打开一本书时的加载态（取 chapterRoads 可能慢）。
  String _openingBook = '';

  /// 反爬验证流程（linovelib 的搜索页要求图片验证码）。
  ///
  /// 复用动漫侧同一份实现 —— 抽到了 services/plugin/captcha_flow.dart。
  late final CaptchaFlow _captchaFlow;

  @override
  void initState() {
    super.initState();
    _input.text = widget.initialQuery;
    final controller = inject<PluginsController>();
    _sources
      ..clear()
      ..addAll(controller.pluginList.where((p) => p.supportsNovel));
    _source = _sources.isEmpty ? null : _sources.first;
    _captchaFlow = CaptchaFlow(
      onVerified: _onVerified,
      onCancelled: (plugin) {
        if (mounted) setState(() => _searching = false);
      },
    );
    if (_input.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _captchaFlow.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final plugin = _source;
    final keyword = _input.text.trim();
    if (plugin == null || keyword.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _error = '';
      _results = const <SearchItem>[];
    });
    try {
      final response = await plugin.queryBangumi(keyword);
      if (!mounted) return;
      // 客户端按关键词过滤。
      //
      // linovelib 的搜索接口要求图片验证码（一次 30 分钟），而榜单页
      // /top/... 免验证、结构完全一样。所以规则把 searchURL 指向榜单，
      // 拿回来的是「这一页的全部书」，需要在这里按书名筛一遍 ——
      // 否则搜「史莱姆」会返回榜单前 30 本毫不相干的书。
      //
      // 命中的留下；一本都没命中时保留全部并提示，让用户至少能翻榜单，
      // 而不是对着空列表不知道发生了什么。
      final matched = _matchByKeyword(response.data, keyword);
      setState(() {
        _results = matched.isEmpty ? response.data : matched;
        _filteredOut = matched.isEmpty && response.data.isNotEmpty;
        _error = '';
      });
    } on CaptchaRequiredException {
      // 站点要求先过验证：弹验证码对话框，验证通过后 onVerified 会重试搜索。
      if (mounted) setState(() => _searching = false);
      _captchaFlow.start(plugin, keyword);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 榜单兜底时，「一本都没命中关键词」的标记，用来在列表上方提示。
  bool _filteredOut = false;

  /// 按书名（或详情链接里的拼音）筛出与 [keyword] 相关的条目。
  ///
  /// 只做包含匹配：把关键词和书名都转小写后比子串。中文不需要分词，
  /// 「史莱姆」在「关于我转生变成史莱姆这档事」里能直接命中。
  /// 全角/半角差异（史萊姆 vs 史莱姆）用一个简易归一化抹平。
  List<SearchItem> _matchByKeyword(List<SearchItem> items, String keyword) {
    final k = _normalize(keyword);
    if (k.isEmpty) return items;
    return items
        .where((item) => _normalize(item.name).contains(k))
        .toList(growable: false);
  }

  String _normalize(String input) {
    return input
        .toLowerCase()
        .replaceAll('萊', '莱')
        .replaceAll('姆', '姆')
        .replaceAll('轉', '转')
        .replaceAll('這', '这')
        .replaceAll('檔', '档')
        .replaceAll('於', '于')
        .replaceAll('個', '个')
        .replaceAll('會', '会')
        .replaceAll('學', '学')
        .replaceAll(RegExp(r'\s+'), '');
  }

  /// 验证通过后的收尾。
  ///
  /// 优先用 WebView 收割到的 [pageHtml] 直接解析 —— 验证码提交后浏览器里
  /// 已经是结果页了，再发一次 HTTP 请求既慢又可能因为 cookie 口径不同而
  /// 再次撞上验证页。解析失败才退回重试搜索（此时 cookie 已存，通常能过）。
  void _onVerified(Plugin plugin, String pageHtml) {
    if (!mounted) return;
    try {
      final harvested = plugin.parseHarvestedSearch(pageHtml);
      if (harvested != null && harvested.data.isNotEmpty) {
        setState(() {
          _results = harvested.data;
          _error = '';
          _searching = false;
        });
        return;
      }
    } catch (_) {
      // 收割页解析不了就走重试
    }
    _search();
  }

  Future<void> _openBook(SearchItem item) async {
    final plugin = _source;
    if (plugin == null || _openingBook.isNotEmpty) return;
    setState(() => _openingBook = item.name);
    try {
      final roads = await plugin.queryChapterRoads(item.src);
      if (!mounted) return;
      if (roads.isEmpty) {
        setState(() => _error = '这本书没有解析出任何章节：规则可能失效了。');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NovelReaderPage(
            plugin: plugin,
            bookTitle: item.name,
            roads: roads,
          ),
        ),
      );
    } catch (e) {
      KazumiLogger().w('novel open book failed: ' + e.toString());
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _openingBook = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SysAppBar(title: const Text('轻小说')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '书名 / 作者',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          if (_sources.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final p in _sources)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(p.name),
                        selected: identical(p, _source),
                        onSelected: (_) => setState(() => _source = p),
                      ),
                    ),
                ],
              ),
            ),
          if (_sources.isEmpty)
            const Expanded(
              child: GeneralEmptyState(
                icon: Icons.auto_stories_outlined,
                title: '还没有小说规则源。\n'
                    '到「我的 → 规则管理」装一条 type=novel 的规则，'
                    '或在规则里填上 chapterContent。',
              ),
            )
          else if (_searching || _openingBook.isNotEmpty)
            const Expanded(child: Center(child: LoadingIndicator()))
          else if (_error.isNotEmpty)
            Expanded(
              child: GeneralEmptyState(
                icon: Icons.error_outline,
                title: _error,
                actions: [
                  FilledButton(onPressed: _search, child: const Text('重试')),
                ],
              ),
            )
          else if (_results.isEmpty)
            const Expanded(
              child: GeneralEmptyState(
                icon: Icons.search,
                title: '输入书名搜一下。\n结果来自当前选中的规则源。',
              ),
            )
          else
            Expanded(
              child: Column(
                children: [
                  if (_filteredOut)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        '这个站点的搜索要过验证码，所以这里列的是排行榜。'
                        '没找到「' + _input.text.trim() + '」，下面是本页全部书目。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, index) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final item = _results[i];
                        return ListTile(
                          leading: const Icon(Icons.menu_book_outlined),
                          title: Text(item.name),
                          subtitle: Text(
                            item.src,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                          onTap: () => _openBook(item),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
