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
  String _pendingKeyword = '';

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
      onVerified: (plugin, pageHtml) {
        // 验证通过后 cookie 已存，直接重试搜索即可。
        _search();
      },
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
    _pendingKeyword = keyword;
    try {
      final response = await plugin.queryBangumi(keyword);
      if (mounted) setState(() => _results = response.data);
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
    );
  }
}
