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

/// 轻小说主页。
///
/// 三个状态：
///   • 刚进来 → 直接显示排行榜（不用先搜索，因为榜单本身就是内容）
///   • 搜过 → 显示搜索结果（网格 + 封面）
///   • 搜索被验证码拦住 → 弹验证码，通过后自动继续
///
/// 搜索完全走规则引擎（linovelib 的 /S6/?searchkey=），不再用「拿榜单当搜索」
/// 的临时方案 —— 那条路只能搜到榜单里的 30 本。
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

  /// true = 当前显示的是搜索结果；false = 排行榜。
  bool _showingSearch = false;

  /// 打开一本书时的加载态（取 chapterRoads 可能慢）。
  String _openingBook = '';

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
    // 进入即加载榜单：用户点开 tab 就该看到书，而不是一张空页面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialQuery.trim().isNotEmpty) {
        _search();
      } else {
        _loadRanking();
      }
    });
  }

  @override
  void dispose() {
    _captchaFlow.dispose();
    _input.dispose();
    super.dispose();
  }

  /// 加载排行榜（免验证码）。
  ///
  /// 榜单是 linovelib 的 /top/monthvisit/，规则里没有这个概念，所以这里直接
  /// 借规则的搜索通道拿 —— 榜单页和搜索结果页的 searchList 选择器不同，
  /// 因此用一个只改 searchURL 的临时 Plugin 副本。
  Future<void> _loadRanking() async {
    final plugin = _source;
    if (plugin == null || _searching) return;
    setState(() {
      _searching = true;
      _error = '';
      _showingSearch = false;
    });
    try {
      final ranking = plugin.forRanking();
      final response = await ranking.queryBangumi('');
      if (!mounted) return;
      setState(() => _results = response.data);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _search() async {
    final plugin = _source;
    final keyword = _input.text.trim();
    if (plugin == null) return;
    if (keyword.isEmpty) {
      await _loadRanking();
      return;
    }
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = '';
      _showingSearch = true;
      _results = const <SearchItem>[];
    });
    try {
      final response = await plugin.queryBangumi(keyword);
      if (!mounted) return;
      setState(() => _results = response.data);
    } on CaptchaRequiredException {
      if (mounted) setState(() => _searching = false);
      _captchaFlow.start(plugin, keyword);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 验证通过后直接用收割到的页面解析，省一次请求。
  void _onVerified(Plugin plugin, String pageHtml) {
    if (!mounted) return;
    try {
      final harvested = plugin.parseHarvestedSearch(pageHtml);
      if (harvested != null && harvested.data.isNotEmpty) {
        setState(() {
          _results = harvested.data;
          _error = '';
          _searching = false;
          _showingSearch = true;
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
                      hintText: '搜书名 / 作者',
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
                        onSelected: (_) {
                          setState(() => _source = p);
                          _loadRanking();
                        },
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
                    '到「我的 → 规则管理」装一条 type=novel 的规则。',
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
                  FilledButton(
                    onPressed: _showingSearch ? _search : _loadRanking,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          else if (_results.isEmpty)
            Expanded(
              child: GeneralEmptyState(
                icon: Icons.search,
                title: _showingSearch
                    ? '没有搜到这本书。\n换个关键词，或者用繁体书名试试。'
                    : '榜单暂时没加载出来，下拉重试。',
                actions: [
                  FilledButton(
                    onPressed: _showingSearch ? _search : _loadRanking,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: _showingSearch ? _search : _loadRanking,
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    childAspectRatio: 0.58,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (context, i) => _BookCard(
                    item: _results[i],
                    theme: theme,
                    onTap: () => _openBook(_results[i]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一本书的封面卡片。
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.item,
    required this.theme,
    required this.onTap,
  });

  final SearchItem item;
  final ThemeData theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item.cover.isEmpty
                  ? Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: const Icon(Icons.menu_book_outlined, size: 28),
                    )
                  : Image.network(
                      item.cover,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      // 图床对 Referer 不敏感（实测带不带都 200），
                      // 但带上更稳妥。
                      headers: const {
                        'referer': 'https://www.linovelib.com/',
                      },
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined, size: 24),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
