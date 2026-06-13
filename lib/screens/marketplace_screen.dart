import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/marketplace_service.dart';
import '../widgets/marketplace_tile.dart' show MarketplaceTile, GradientPlaceholder;

/// 3D 形象市场浏览页
/// - 顶部 SliverAppBar 含搜索框
/// - 主体是 filter chips + 排序菜单 + GridView 分页
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  static const _typeFilters = <_TypeFilter>[
    _TypeFilter(value: 'all', label: '全部'),
    _TypeFilter(value: 'text-to-3d', label: '文生3D'),
    _TypeFilter(value: 'image-to-3d', label: '单图3D'),
    _TypeFilter(value: 'multi-image-to-3d', label: '多图3D'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadMarketplace();
    });
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      context.read<AppState>().loadMarketplaceNextPage();
    }
  }

  Future<void> _refresh() async {
    await context.read<AppState>().loadMarketplace();
  }

  void _onSearchSubmitted(String value) {
    context.read<AppState>().setMarketplaceFilters(query: value.trim());
  }

  void _onTypeSelected(String type) {
    context.read<AppState>().setMarketplaceFilters(type: type);
  }

  void _onSortSelected(String sort) {
    context.read<AppState>().setMarketplaceFilters(sort: sort);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scrollCtrl,
          slivers: [
            SliverAppBar(
              floating: true,
              pinned: true,
              title: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: '搜索形象…',
                  border: InputBorder.none,
                  isDense: true,
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? const Icon(Icons.search, size: 20)
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            _onSearchSubmitted('');
                          },
                        ),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: _onSearchSubmitted,
              ),
              actions: [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.sort),
                  tooltip: '排序',
                  onSelected: _onSortSelected,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'recent', child: Text('最新发布')),
                    PopupMenuItem(value: 'popular', child: Text('最受欢迎')),
                  ],
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: _typeFilters.map((f) {
                    final selected = state.marketplaceType == f.value;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      child: ChoiceChip(
                        label: Text(f.label),
                        selected: selected,
                        onSelected: (_) => _onTypeSelected(f.value),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            if (state.marketplaceLoading && state.marketplaceCache.isEmpty)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.marketplaceError != null &&
                state.marketplaceCache.isEmpty)
              SliverFillRemaining(
                child: _ErrorView(
                  message: state.marketplaceError!,
                  onRetry: _refresh,
                ),
              )
            else if (state.marketplaceCache.isEmpty)
              const SliverFillRemaining(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      '市场里还没有公开模型\n快去生成第一个吧',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    childAspectRatio: 0.78,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final item = state.marketplaceCache[i];
                      return MarketplaceTile(
                        item: item,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                MarketplaceDetailScreen(item: item),
                          ),
                        ),
                      );
                    },
                    childCount: state.marketplaceCache.length,
                  ),
                ),
              ),
            if (state.marketplaceLoading && state.marketplaceCache.isNotEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TypeFilter {
  final String value;
  final String label;
  const _TypeFilter({required this.value, required this.label});
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// MarketplaceDetailScreen
// ════════════════════════════════════════════════════════════════════

class MarketplaceDetailScreen extends StatefulWidget {
  const MarketplaceDetailScreen({super.key, required this.item});
  final MarketplaceItem item;

  @override
  State<MarketplaceDetailScreen> createState() =>
      _MarketplaceDetailScreenState();
}

class _MarketplaceDetailScreenState extends State<MarketplaceDetailScreen> {
  late MarketplaceItem _item;
  bool _adopting = false;
  String? _adoptError;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
  }

  Future<void> _adopt() async {
    setState(() {
      _adopting = true;
      _adoptError = null;
    });
    try {
      final fresh = await context
          .read<AppState>()
          .marketplace
          .download(_item.id);
      if (!mounted) return;
      setState(() => _item = fresh);
      await context.read<AppState>().setActiveMarketplaceModel(_item.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已选用此模型作为当前 3D 形象')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _adoptError = e.toString());
    } finally {
      if (mounted) setState(() => _adopting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final glbUrl = state.marketplace.resolveGlbUrl(_item);
    final previewUrl = state.marketplace.resolvePreviewUrl(_item);
    return Scaffold(
      appBar: AppBar(title: Text(_item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        children: [
          // 3D 预览
          Container(
            color: Colors.black12,
            height: 320,
            child: glbUrl.isNotEmpty
                ? ModelViewer(
                    src: glbUrl,
                    alt: _item.displayTitle,
                    autoRotate: true,
                    cameraControls: true,
                    disableZoom: false,
                    backgroundColor: Colors.transparent,
                    poster: previewUrl.isNotEmpty ? previewUrl : null,
                    shadowIntensity: 0.5,
                    exposure: 0.9,
                  )
                : (previewUrl.isNotEmpty
                    ? Image.network(previewUrl, fit: BoxFit.contain)
                    : const GradientPlaceholder()),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_outline, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('@${_item.ownerShort}',
                        style: const TextStyle(color: Colors.grey)),
                    const Spacer(),
                    const Icon(Icons.download, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('${_item.downloads}',
                        style: const TextStyle(color: Colors.grey)),
                    const SizedBox(width: 12),
                    const Icon(Icons.visibility, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('${_item.views}',
                        style: const TextStyle(color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _MetaChip(label: _typeZhFull(_item.taskType)),
                    _MetaChip(label: 'quality=${_item.textureQuality}'),
                    _MetaChip(label: _item.modelName),
                    if (_item.status != 'SUCCEEDED')
                      _MetaChip(label: 'status=${_item.status}', color: Colors.orange),
                  ],
                ),
                if (_item.prompt != null && _item.prompt!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('提示词', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(_item.prompt!),
                ],
                if (_item.tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(_item.tags,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
                if (_adoptError != null) ...[
                  const SizedBox(height: 12),
                  Text('选用失败：$_adoptError',
                      style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _adopting || _item.status != 'SUCCEEDED'
                            ? null
                            : _adopt,
                        icon: const Icon(Icons.check),
                        label: Text(
                          state.activeMarketplaceModelId == _item.id
                              ? '当前正在使用'
                              : '选用此模型',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '由 @${_item.ownerShort} 在 ${_item.createdAt.toLocal().toString().substring(0, 16)} 分享',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _typeZhFull(String t) {
    switch (t) {
      case 'text-to-3d':
        return '文生 3D';
      case 'image-to-3d':
        return '单图 3D';
      case 'multi-image-to-3d':
        return '多图 3D';
      default:
        return t;
    }
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.5), width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: c)),
    );
  }
}
