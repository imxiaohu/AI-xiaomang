import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/model_viewer_settings.dart';

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const SettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xff1e1e2e),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            _buildHandle(),
            _buildHeader(ctx),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  const SizedBox(height: 8),
                  _buildSectionTitle('3D模型显示'),
                  const _ModelDisplaySection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('3D生成质量'),
                  const _ModelQualitySection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('形象管理'),
                  const _AvatarManagementSection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('摄像头'),
                  const _CameraSection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('显示'),
                  const _DisplaySection(),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          const Icon(Icons.settings, color: Color(0xff635bff), size: 22),
          const SizedBox(width: 8),
          const Text(
            '设置',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54, size: 22),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xff635bff),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ModelDisplaySection extends StatelessWidget {
  const _ModelDisplaySection();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final s = appState.settings;

    return _SettingsCard(
      children: [
        _SwitchTile(
          title: '自动旋转模型',
          subtitle: '模型加载后自动缓慢旋转',
          icon: Icons.rotate_right,
          value: s.autoRotate,
          onChanged: (v) => appState.updateSetting(autoRotate: v),
        ),
        const Divider(color: Colors.white10, height: 1),
        _SliderTile(
          title: '阴影强度',
          icon: Icons.brightness_medium,
          value: s.shadowIntensity,
          min: 0.0,
          max: 1.0,
          divisions: 10,
          label: '${(s.shadowIntensity * 100).round()}%',
          onChanged: (v) => appState.updateSetting(shadowIntensity: v),
        ),
        const Divider(color: Colors.white10, height: 1),
        _SliderTile(
          title: '曝光度',
          icon: Icons.wb_sunny_outlined,
          value: s.exposure,
          min: 0.1,
          max: 2.0,
          divisions: 19,
          label: s.exposure.toStringAsFixed(1),
          onChanged: (v) => appState.updateSetting(exposure: v),
        ),
      ],
    );
  }
}

class _ModelQualitySection extends StatelessWidget {
  const _ModelQualitySection();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final s = appState.settings;

    return _SettingsCard(
      children: [
        _SegmentTile(
          title: '生成模型类型',
          icon: Icons.view_in_ar,
          options: ModelViewerOptions.tripoModelLabels,
          selectedIndex: ModelViewerOptions.tripoModelOptions
              .indexOf(s.tripoModel).clamp(0, 1),
          onChanged: (i) => appState.updateSetting(
            tripoModel: ModelViewerOptions.tripoModelOptions[i],
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        _SegmentTile(
          title: '贴图质量',
          icon: Icons.texture,
          options: ModelViewerOptions.textureQualityLabels,
          selectedIndex: ModelViewerOptions.textureQualityOptions
              .indexOf(s.textureQuality).clamp(0, 1),
          onChanged: (i) => appState.updateSetting(
            textureQuality: ModelViewerOptions.textureQualityOptions[i],
          ),
        ),
      ],
    );
  }
}

class _AvatarManagementSection extends StatelessWidget {
  const _AvatarManagementSection();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final hasAvatar = appState.hasAvatar;
    final previewUrl = appState.avatarPreviewUrl;

    return _SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0xff2a2a3e),
                  border: Border.all(
                    color: const Color(0xff635bff).withValues(alpha: 0.3),
                  ),
                ),
                child: previewUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.network(
                          previewUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.person,
                            color: Colors.white30,
                            size: 28,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.person,
                        color: Colors.white30,
                        size: 28,
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasAvatar ? '当前AI形象' : '未设置形象',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasAvatar ? '已保存到本地' : '点击右下角+号生成3D形象',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasAvatar)
                TextButton(
                  onPressed: () async {
                    await appState.clearAvatar();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red.shade300,
                  ),
                  child: const Text('清除'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CameraSection extends StatelessWidget {
  const _CameraSection();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final s = appState.settings;

    return _SettingsCard(
      children: [
        _SwitchTile(
          title: '默认开启闪光灯',
          subtitle: '切换到后摄时自动开启',
          icon: Icons.flash_on,
          value: s.flashDefaultOn,
          onChanged: (v) => appState.updateSetting(flashDefaultOn: v),
        ),
        const Divider(color: Colors.white10, height: 1),
        _SwitchTile(
          title: '默认后置摄像头',
          subtitle: '启动时优先使用后摄',
          icon: Icons.camera_rear,
          value: s.defaultBackCamera,
          onChanged: (v) => appState.updateSetting(defaultBackCamera: v),
        ),
      ],
    );
  }
}

class _DisplaySection extends StatelessWidget {
  const _DisplaySection();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final s = appState.settings;

    return _SettingsCard(
      children: [
        _SwitchTile(
          title: '优先显示3D球体',
          subtitle: '即使有模型也显示动画球体',
          icon: Icons.circle_outlined,
          value: s.prefer3DBall,
          onChanged: (v) => appState.updateSetting(prefer3DBall: v),
        ),
        const Divider(color: Colors.white10, height: 1),
        _SwitchTile(
          title: '显示调试信息',
          subtitle: '显示帧率、延迟等调试数据',
          icon: Icons.bug_report,
          value: s.showDebugInfo,
          onChanged: (v) => appState.updateSetting(showDebugInfo: v),
        ),
      ],
    );
  }
}

// ---- Reusable widgets ----

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xff252536),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(children: children),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: Colors.white38, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xff635bff),
          ),
        ],
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.title,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white38, size: 20),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const Spacer(),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xff635bff),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xff635bff),
              inactiveTrackColor: Colors.white12,
              thumbColor: const Color(0xff635bff),
              overlayColor: const Color(0xff635bff).withValues(alpha: 0.2),
              trackHeight: 3,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _SegmentTile({
    required this.title,
    required this.icon,
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white38, size: 20),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: List.generate(options.length, (i) {
              final selected = i == selectedIndex;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: Container(
                    margin: EdgeInsets.only(right: i < options.length - 1 ? 8 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xff635bff)
                          : const Color(0xff2a2a3e),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected
                            ? const Color(0xff635bff)
                            : Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        options[i],
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white54,
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
