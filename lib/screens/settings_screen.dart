import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/enums.dart';
import '../providers/app_state.dart';
import '../services/marketplace_service.dart';
import '../services/settings_service.dart';
import 'marketplace_screen.dart';

/// 统一设置页
/// 集中管理：后端、AI 模式、TTS、3D 模型、ASR、外观、About。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _draft;
  late TextEditingController _backendCtrl;
  late TextEditingController _tokenCtrl;
  bool _initialized = false;
  bool _testing = false;
  // 用于 3D 模型 → 缓存区块：实时拉取
  int _cacheModelCount = 0;
  int _cacheTotalBytes = 0;
  bool _clearingCache = false;

  @override
  void initState() {
    super.initState();
    _draft = context.read<AppState>().settings;
    _backendCtrl = TextEditingController(text: _draft.backendUrl);
    _tokenCtrl = TextEditingController(text: _draft.authToken);
    _initialized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshCache();
      context.read<AppState>().loadMyModels();
    });
  }

  @override
  void dispose() {
    _backendCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshCache() async {
    try {
      final stats = await context.read<AppState>().marketplace.cacheStats();
      if (!mounted) return;
      setState(() {
        _cacheModelCount = (stats['model_count'] ?? 0) as int;
        _cacheTotalBytes = (stats['total_bytes'] ?? 0) as int;
      });
    } catch (_) {
      // 忽略：可能后端无 marketplace 路由
    }
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    final ok = await context
        .read<AppState>()
        .testBackendConnection(overrideUrl: _backendCtrl.text.trim());
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '✓ 连接成功' : '✗ 连接失败（请检查后端地址）'),
        backgroundColor: ok ? Colors.green : Colors.redAccent,
      ),
    );
  }

  Future<void> _applySettings() async {
    final next = _draft.copyWith(
      backendUrl: _backendCtrl.text.trim(),
      authToken: _tokenCtrl.text.trim(),
    );
    await context.read<AppState>().updateSettings(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已应用')),
    );
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清理本地缓存？'),
        content: const Text('将删除 models_cache/ 目录中所有本地缓存的 GLB / 预览文件。\n'
            '（不会删除云端 3D 形象市场里的模型记录）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearingCache = true);
    final removed =
        await context.read<AppState>().marketplace.clearCache(olderThanDays: 0);
    if (!mounted) return;
    setState(() => _clearingCache = false);
    await _refreshCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清理 $removed 个文件')),
    );
  }

  Future<void> _resetAllSettings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重置所有设置？'),
        content: const Text('将清空所有偏好（后端地址、令牌、默认模型等），回到出厂状态。\n'
            '已保存的 3D 形象市场模型不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppState>().resetSettings();
    setState(() {
      _draft = const AppSettings();
      _backendCtrl.text = _draft.backendUrl;
      _tokenCtrl.text = _draft.authToken;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          IconButton(
            tooltip: '应用',
            icon: const Icon(Icons.check),
            onPressed: _applySettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _ServerSection(
            backendCtrl: _backendCtrl,
            tokenCtrl: _tokenCtrl,
            onTest: _testing ? null : _testConnection,
          ),
          _AiSection(
            runMode: _draft.defaultRunMode,
            omniMode: _draft.defaultOmniMode,
            onRunModeChanged: (v) =>
                setState(() => _draft = _draft.copyWith(defaultRunMode: v)),
            onOmniModeChanged: (v) =>
                setState(() => _draft = _draft.copyWith(defaultOmniMode: v)),
          ),
          _TtsSection(
            voice: _draft.ttsVoice,
            rate: _draft.ttsRate,
            volume: _draft.ttsVolume,
            onVoiceChanged: (v) =>
                setState(() => _draft = _draft.copyWith(ttsVoice: v)),
            onRateChanged: (v) =>
                setState(() => _draft = _draft.copyWith(ttsRate: v)),
            onVolumeChanged: (v) =>
                setState(() => _draft = _draft.copyWith(ttsVolume: v)),
          ),
          _ModelsSection(
            tripoModel: _draft.tripoModel,
            tripoTexture: _draft.tripoTextureQuality,
            visibility: _draft.defaultModelVisibility,
            onTripoModelChanged: (v) =>
                setState(() => _draft = _draft.copyWith(tripoModel: v)),
            onTripoTextureChanged: (v) =>
                setState(() => _draft = _draft.copyWith(tripoTextureQuality: v)),
            onVisibilityChanged: (v) => setState(
                () => _draft = _draft.copyWith(defaultModelVisibility: v)),
            onOpenMarketplace: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MarketplaceScreen()),
            ),
            cacheModelCount: _cacheModelCount,
            cacheTotalBytes: _cacheTotalBytes,
            onClearCache: _clearingCache ? null : _clearCache,
            onRefreshCache: _refreshCache,
            state: state,
            onSetVisibility: (id, v) => state.setModelVisibility(id, v),
            onDelete: (id) async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('删除该模型？'),
                  content: const Text('将从云端市场和本地缓存中一并删除，无法恢复。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('删除', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
              if (confirmed == true) await state.deleteModel(id);
            },
            onUseModel: (id) async {
              await state.setActiveMarketplaceModel(id);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已选用该模型作为当前形象')),
              );
            },
          ),
          _AsrSection(state: state),
          _AppearanceSection(
            mode: _draft.themeMode,
            onChanged: (m) => setState(() => _draft = _draft.copyWith(themeMode: m)),
          ),
          _AboutSection(backendUrl: state.backendBaseUrl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextButton.icon(
              icon: const Icon(Icons.restart_alt, color: Colors.red),
              label: const Text('重置所有设置',
                  style: TextStyle(color: Colors.red)),
              onPressed: _resetAllSettings,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 通用小工具
// ════════════════════════════════════════════════════════════════════

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

// ════════════════════════════════════════════════════════════════════
// 1) Server
// ════════════════════════════════════════════════════════════════════

class _ServerSection extends StatelessWidget {
  const _ServerSection({
    required this.backendCtrl,
    required this.tokenCtrl,
    required this.onTest,
  });
  final TextEditingController backendCtrl;
  final TextEditingController tokenCtrl;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'SERVER · 后端',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: backendCtrl,
            decoration: const InputDecoration(
              labelText: '后端地址',
              helperText: '留空则使用编译期默认值（如 http://192.168.x.x:8000）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            controller: tokenCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '用户令牌',
              helperText: '会以 X-User-Token 头随每次请求发送',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: onTest,
                icon: const Icon(Icons.network_check, size: 18),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              const Text('会向 /health 发送一个 GET',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 2) AI & Run mode
// ════════════════════════════════════════════════════════════════════

class _AiSection extends StatelessWidget {
  const _AiSection({
    required this.runMode,
    required this.omniMode,
    required this.onRunModeChanged,
    required this.onOmniModeChanged,
  });
  final AppRunMode runMode;
  final OmniInteractionMode omniMode;
  final ValueChanged<AppRunMode> onRunModeChanged;
  final ValueChanged<OmniInteractionMode> onOmniModeChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'AI · 运行模式',
      children: [
        RadioListTile<AppRunMode>(
          title: const Text('云端阿里云（默认）'),
          subtitle: const Text('阿里云 VL/TTS · 速度快 · 需网络'),
          value: AppRunMode.cloudAliyun,
          groupValue: runMode,
          onChanged: (v) {
            if (v != null) onRunModeChanged(v);
          },
        ),
        RadioListTile<AppRunMode>(
          title: const Text('离线本地'),
          subtitle: const Text('端侧 Qwen2-VL · 隐私好 · 首次需下载模型'),
          value: AppRunMode.offlineLocal,
          groupValue: runMode,
          onChanged: (v) {
            if (v != null) onRunModeChanged(v);
          },
        ),
        const Divider(),
        RadioListTile<OmniInteractionMode>(
          title: const Text('手动（长按说话）'),
          value: OmniInteractionMode.manual,
          groupValue: omniMode,
          onChanged: (v) {
            if (v != null) onOmniModeChanged(v);
          },
        ),
        RadioListTile<OmniInteractionMode>(
          title: const Text('VAD 自动语音检测'),
          value: OmniInteractionMode.vad,
          groupValue: omniMode,
          onChanged: (v) {
            if (v != null) onOmniModeChanged(v);
          },
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 3) TTS
// ════════════════════════════════════════════════════════════════════

class _TtsSection extends StatelessWidget {
  const _TtsSection({
    required this.voice,
    required this.rate,
    required this.volume,
    required this.onVoiceChanged,
    required this.onRateChanged,
    required this.onVolumeChanged,
  });
  final String voice;
  final double rate;
  final double volume;
  final ValueChanged<String> onVoiceChanged;
  final ValueChanged<double> onRateChanged;
  final ValueChanged<double> onVolumeChanged;

  /// 与后端 config.py TTS 音色列表对齐
  static const _voices = <String>[
    'Cherry', 'Serena', 'Ethan', 'Chelsie', 'Momo', 'Vivian', 'Moon',
    'Maia', 'Kai', 'Nofish', 'Bella', 'Jennifer', 'Ryan', 'Katerina',
    'Aiden', 'Eldric Sage', 'Mia', 'Mochi', 'Bellona', 'Vincent', 'Bunny',
    'Neil', 'Elias', 'Arthur', 'Nini', 'Seren', 'Pip', 'Stella',
    'Jada', 'Dylan', 'Li', 'Marcus', 'Roy', 'Peter', 'Sunny', 'Eric',
    'Rocky', 'Kiki',
  ];

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'TTS · 语音播报',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: DropdownButtonFormField<String>(
            value: _voices.contains(voice) ? voice : _voices.first,
            decoration: const InputDecoration(
              labelText: '音色',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: _voices
                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                .toList(),
            onChanged: (v) {
              if (v != null) onVoiceChanged(v);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('语速：${rate.toStringAsFixed(1)}',
              style: const TextStyle(fontSize: 12)),
        ),
        Slider(
          value: rate,
          min: 0.3,
          max: 1.0,
          divisions: 7,
          label: rate.toStringAsFixed(1),
          onChanged: onRateChanged,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text('音量：${(volume * 100).toInt()}%',
              style: const TextStyle(fontSize: 12)),
        ),
        Slider(
          value: volume,
          min: 0.0,
          max: 1.0,
          divisions: 10,
          label: '${(volume * 100).toInt()}%',
          onChanged: onVolumeChanged,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 4) 3D Models（含"我的模型"与"缓存"）
// ════════════════════════════════════════════════════════════════════

class _ModelsSection extends StatelessWidget {
  const _ModelsSection({
    required this.tripoModel,
    required this.tripoTexture,
    required this.visibility,
    required this.onTripoModelChanged,
    required this.onTripoTextureChanged,
    required this.onVisibilityChanged,
    required this.onOpenMarketplace,
    required this.cacheModelCount,
    required this.cacheTotalBytes,
    required this.onClearCache,
    required this.onRefreshCache,
    required this.state,
    required this.onSetVisibility,
    required this.onDelete,
    required this.onUseModel,
  });

  final String tripoModel;
  final String tripoTexture;
  final String visibility;
  final ValueChanged<String> onTripoModelChanged;
  final ValueChanged<String> onTripoTextureChanged;
  final ValueChanged<String> onVisibilityChanged;
  final VoidCallback onOpenMarketplace;
  final int cacheModelCount;
  final int cacheTotalBytes;
  final VoidCallback? onClearCache;
  final VoidCallback onRefreshCache;
  final AppState state;
  final Future<void> Function(String modelId, String visibility) onSetVisibility;
  final Future<void> Function(String modelId) onDelete;
  final Future<void> Function(String modelId) onUseModel;

  static const _tripoModels = <String>[
    'Tripo/Tripo-P1.0',
    'Tripo/Tripo-H3.1',
  ];

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: '3D MODELS · 3D 形象',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: DropdownButtonFormField<String>(
            value: _tripoModels.contains(tripoModel)
                ? tripoModel
                : _tripoModels.first,
            decoration: const InputDecoration(
              labelText: '生成模型',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: _tripoModels
                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                .toList(),
            onChanged: (v) {
              if (v != null) onTripoModelChanged(v);
            },
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text('贴图质量：'),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('standard'),
                selected: tripoTexture == 'standard',
                onSelected: (_) => onTripoTextureChanged('standard'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('detailed'),
                selected: tripoTexture == 'detailed',
                onSelected: (_) => onTripoTextureChanged('detailed'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('新模型默认可见性',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
        ),
        RadioListTile<String>(
          title: const Text('公开 public'),
          subtitle: const Text('任何人都能在形象市场看到并选用'),
          value: 'public',
          groupValue: visibility,
          onChanged: (v) {
            if (v != null) onVisibilityChanged(v);
          },
        ),
        RadioListTile<String>(
          title: const Text('不公开 unlisted'),
          subtitle: const Text('拿到链接的人可以看到'),
          value: 'unlisted',
          groupValue: visibility,
          onChanged: (v) {
            if (v != null) onVisibilityChanged(v);
          },
        ),
        RadioListTile<String>(
          title: const Text('私密 private'),
          subtitle: const Text('只有你自己能看到'),
          value: 'private',
          groupValue: visibility,
          onChanged: (v) {
            if (v != null) onVisibilityChanged(v);
          },
        ),
        const Divider(),
        // ── 我的模型 ──
        ListTile(
          title: const Text('我的模型'),
          subtitle: Text('共 ${state.myModels.length} 个'),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => state.loadMyModels(),
          ),
        ),
        if (state.myModelsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (state.myModelsError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('加载失败：${state.myModelsError}',
                style: const TextStyle(color: Colors.redAccent)),
          )
        else if (state.myModels.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('还没有生成过 3D 模型',
                style: TextStyle(color: Colors.grey)),
          )
        else
          ...state.myModels.map((item) => _MyModelRow(
                item: item,
                onSetVisibility: (v) => onSetVisibility(item.id, v),
                onDelete: () => onDelete(item.id),
                onUse: () => onUseModel(item.id),
              )),
        const Divider(),
        // ── 缓存 ──
        ListTile(
          title: const Text('本地缓存'),
          subtitle: Text(
              '$cacheModelCount 个模型 · ${_formatBytes(cacheTotalBytes)}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: onRefreshCache,
              ),
              TextButton(
                onPressed: onClearCache,
                child: const Text('清理'),
              ),
            ],
          ),
        ),
        const Divider(),
        // ── 打开市场 ──
        ListTile(
          leading: const Icon(Icons.store_mall_directory_outlined),
          title: const Text('打开 3D 形象市场'),
          subtitle: const Text('浏览所有公开模型 · 选用 · 收藏'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onOpenMarketplace,
        ),
      ],
    );
  }
}

class _MyModelRow extends StatelessWidget {
  const _MyModelRow({
    required this.item,
    required this.onSetVisibility,
    required this.onDelete,
    required this.onUse,
  });
  final MarketplaceItem item;
  final ValueChanged<String> onSetVisibility;
  final VoidCallback onDelete;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: item.previewUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(item.previewUrl!, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.image)),
              )
            : const Icon(Icons.abc),
      ),
      title: Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          _MiniChip(label: _typeZh(item.taskType)),
          const SizedBox(width: 6),
          _MiniChip(label: _visZh(item.visibility), color: _visColor(item.visibility)),
          const SizedBox(width: 6),
          Text('⬇ ${item.downloads}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
      children: [
        ListTile(
          dense: true,
          title: const Text('可见性'),
          trailing: DropdownButton<String>(
            value: item.visibility,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 'public', child: Text('公开')),
              DropdownMenuItem(value: 'unlisted', child: Text('不公开')),
              DropdownMenuItem(value: 'private', child: Text('私密')),
            ],
            onChanged: (v) {
              if (v != null) onSetVisibility(v);
            },
          ),
        ),
        ListTile(
          dense: true,
          title: const Text('选用此模型作为当前形象'),
          trailing: TextButton.icon(
            icon: const Icon(Icons.check, size: 16),
            label: const Text('选用'),
            onPressed: onUse,
          ),
        ),
        ListTile(
          dense: true,
          title: const Text('删除', style: TextStyle(color: Colors.red)),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: onDelete,
          ),
        ),
      ],
    );
  }

  static String _typeZh(String t) {
    switch (t) {
      case 'text-to-3d':
        return '文生';
      case 'image-to-3d':
        return '图生';
      case 'multi-image-to-3d':
        return '多图';
      default:
        return t;
    }
  }

  static String _visZh(String v) {
    switch (v) {
      case 'public':
        return '公开';
      case 'unlisted':
        return '不公开';
      case 'private':
        return '私密';
      default:
        return v;
    }
  }

  static Color? _visColor(String v) {
    switch (v) {
      case 'public':
        return Colors.green;
      case 'unlisted':
        return Colors.orange;
      case 'private':
        return Colors.grey;
      default:
        return null;
    }
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.blueGrey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.withOpacity(0.5), width: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: c)),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 5) ASR / Offline
// ════════════════════════════════════════════════════════════════════

class _AsrSection extends StatelessWidget {
  const _AsrSection({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'ASR · 离线语音',
      children: [
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Vosk 中文模型'),
          subtitle: Text(state.isDownloading
              ? '下载中：${(state.downloadProgress * 100).toStringAsFixed(0)}% · ${state.downloadCurrentFile ?? ''}'
              : (state.asrAvailable ? '已就绪' : '未加载')),
        ),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Qwen2-VL 视觉模型'),
          subtitle: Text(state.vlAvailable ? '已就绪' : '未加载或被降级'),
        ),
        ListTile(
          leading: const Icon(Icons.memory),
          title: const Text('本地模型根目录'),
          subtitle: Text(
            state.offlineModelsDir ?? '（未初始化）',
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            label: const Text('重新下载 / 修复'),
            onPressed: state.isDownloading
                ? null
                : () => state.retryOfflineDownload(),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 6) Appearance
// ════════════════════════════════════════════════════════════════════

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.mode, required this.onChanged});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: '外观 · 主题',
      children: [
        RadioListTile<ThemeMode>(
          title: const Text('跟随系统'),
          value: ThemeMode.system,
          groupValue: mode,
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
        RadioListTile<ThemeMode>(
          title: const Text('浅色'),
          value: ThemeMode.light,
          groupValue: mode,
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
        RadioListTile<ThemeMode>(
          title: const Text('深色'),
          value: ThemeMode.dark,
          groupValue: mode,
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 7) About
// ════════════════════════════════════════════════════════════════════

class _AboutSection extends StatefulWidget {
  const _AboutSection({required this.backendUrl});
  final String backendUrl;

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  String? _backendVersion;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 不复用 MarketplaceService 的 client（避免和它争抢连接）
      final ok = await context.read<AppState>().testBackendConnection();
      if (!mounted) return;
      setState(() {
        _backendVersion = ok ? '已连接' : '未连接';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'ABOUT · 关于',
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('AI 小芒 客户端'),
          subtitle: const Text('1.0.0+1'),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('后端地址'),
          subtitle: Text(widget.backendUrl,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ),
        ListTile(
          leading: const Icon(Icons.health_and_safety_outlined),
          title: const Text('后端健康检查'),
          subtitle: _loading
              ? const Text('检查中…')
              : _error != null
                  ? Text('错误：$_error',
                      style: const TextStyle(color: Colors.redAccent))
                  : Text(_backendVersion ?? '—'),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ),
      ],
    );
  }
}
