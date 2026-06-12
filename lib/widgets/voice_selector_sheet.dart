import 'package:flutter/material.dart';

/// TTS 音色选项
class TtsVoiceOption {
  final String voice;
  final String label;
  final String description;
  final String gender; // 'female' | 'male'

  const TtsVoiceOption({
    required this.voice,
    required this.label,
    required this.description,
    required this.gender,
  });
}

/// TTS 音色列表（与后端 aliyun_tts.py 常量保持一致）
const List<TtsVoiceOption> kTtsVoices = [
  // ── 中文普通话 · 女 ──
  TtsVoiceOption(voice: 'Cherry',   label: 'Cherry',   description: '阳光积极 · 亲切自然',   gender: 'female'),
  TtsVoiceOption(voice: 'Serena',   label: 'Serena',   description: '温柔小姐姐',            gender: 'female'),
  TtsVoiceOption(voice: 'Chelsie', label: 'Chelsie',  description: '二次元虚拟女友',         gender: 'female'),
  TtsVoiceOption(voice: 'Momo',    label: 'Momo',     description: '撒娇搞怪',              gender: 'female'),
  TtsVoiceOption(voice: 'Vivian',  label: 'Vivian',   description: '拽拽可爱小暴躁',         gender: 'female'),
  TtsVoiceOption(voice: 'Maia',    label: 'Maia',     description: '知性温柔',              gender: 'female'),
  TtsVoiceOption(voice: 'Bella',   label: 'Bella',    description: '萌宝小萝莉',            gender: 'female'),
  TtsVoiceOption(voice: 'Jennifer',label: 'Jennifer',  description: '品牌级美语女声',         gender: 'female'),
  TtsVoiceOption(voice: 'Katerina',label: 'Katerina',  description: '御姐',                  gender: 'female'),
  TtsVoiceOption(voice: 'Mia',     label: 'Mia',      description: '乖小妹温顺乖巧',         gender: 'female'),
  TtsVoiceOption(voice: 'Bellona', label: 'Bellona',  description: '金戈铁马江湖女声',       gender: 'female'),
  TtsVoiceOption(voice: 'Bunny',   label: 'Bunny',    description: '萌属性小萝莉',           gender: 'female'),
  TtsVoiceOption(voice: 'Nini',    label: 'Nini',     description: '邻家妹妹软黏甜腻',        gender: 'female'),
  TtsVoiceOption(voice: 'Seren',   label: 'Seren',    description: '温和舒缓助眠',           gender: 'female'),
  TtsVoiceOption(voice: 'Stella',  label: 'Stella',   description: '甜腻正义少女',           gender: 'female'),
  // ── 中文普通话 · 男 ──
  TtsVoiceOption(voice: 'Ethan',    label: 'Ethan',    description: '标准普通话阳光温暖',      gender: 'male'),
  TtsVoiceOption(voice: 'Moon',     label: 'Moon',     description: '率性帅气',              gender: 'male'),
  TtsVoiceOption(voice: 'Kai',     label: 'Kai',      description: '耳朵SPA',               gender: 'male'),
  TtsVoiceOption(voice: 'Nofish',  label: 'Nofish',   description: '不会翘舌音',             gender: 'male'),
  TtsVoiceOption(voice: 'Ryan',    label: 'Ryan',     description: '甜茶节奏炸裂',           gender: 'male'),
  TtsVoiceOption(voice: 'Aiden',   label: 'Aiden',    description: '美语大男孩',             gender: 'male'),
  TtsVoiceOption(voice: 'Eldric Sage', label: 'Eldric Sage', description: '沉稳睿智老者',  gender: 'male'),
  TtsVoiceOption(voice: 'Mochi',   label: 'Mochi',    description: '聪明伶俐小大人',          gender: 'male'),
  TtsVoiceOption(voice: 'Vincent',  label: 'Vincent',  description: '沙哑烟嗓江湖',            gender: 'male'),
  TtsVoiceOption(voice: 'Neil',    label: 'Neil',     description: '专业新闻主持',            gender: 'male'),
  TtsVoiceOption(voice: 'Elias',   label: 'Elias',    description: '学科严谨叙事讲师',        gender: 'male'),
  TtsVoiceOption(voice: 'Arthur',  label: 'Arthur',   description: '质朴沧桑老者',            gender: 'male'),
  TtsVoiceOption(voice: 'Pip',     label: 'Pip',      description: '顽屁小孩调皮童真',        gender: 'male'),
  // ── 中文方言 ──
  TtsVoiceOption(voice: 'Jada',    label: 'Jada',     description: '上海阿珍风风火火',        gender: 'female'),
  TtsVoiceOption(voice: 'Dylan',   label: 'Dylan',    description: '北京胡同少年',            gender: 'male'),
  TtsVoiceOption(voice: 'Li',      label: 'Li',       description: '南京耐心瑜伽老师',         gender: 'male'),
  TtsVoiceOption(voice: 'Marcus',  label: 'Marcus',   description: '陕西老陕',                gender: 'male'),
  TtsVoiceOption(voice: 'Roy',     label: 'Roy',      description: '闽南阿杰市井活泼',         gender: 'male'),
  TtsVoiceOption(voice: 'Peter',   label: 'Peter',    description: '天津相声捧哏',            gender: 'male'),
  TtsVoiceOption(voice: 'Sunny',   label: 'Sunny',    description: '四川甜到心里川妹',        gender: 'female'),
  TtsVoiceOption(voice: 'Eric',   label: 'Eric',     description: '四川跳脱市井',            gender: 'male'),
  TtsVoiceOption(voice: 'Rocky',   label: 'Rocky',    description: '粤语幽默风趣',            gender: 'male'),
  TtsVoiceOption(voice: 'Kiki',    label: 'Kiki',     description: '粤语甜美港妹',            gender: 'female'),
];

/// 底部弹出音色选择 Sheet
class VoiceSelectorSheet extends StatefulWidget {
  final String selectedVoice;
  final ValueChanged<String> onVoiceSelected;

  const VoiceSelectorSheet({
    super.key,
    required this.selectedVoice,
    required this.onVoiceSelected,
  });

  static Future<void> show(
    BuildContext context, {
    required String selectedVoice,
    required ValueChanged<String> onVoiceSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff1e1e2e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollCtrl) => VoiceSelectorSheet(
          selectedVoice: selectedVoice,
          onVoiceSelected: (v) {
            onVoiceSelected(v);
            Navigator.of(ctx).pop();
          },
        ),
      ),
    );
  }

  @override
  State<VoiceSelectorSheet> createState() => _VoiceSelectorSheetState();
}

class _VoiceSelectorSheetState extends State<VoiceSelectorSheet> {
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  List<TtsVoiceOption> get _filtered {
    if (_searchQuery.isEmpty) return kTtsVoices;
    final q = _searchQuery.toLowerCase();
    return kTtsVoices.where((v) =>
      v.label.toLowerCase().contains(q) ||
      v.description.toLowerCase().contains(q) ||
      v.voice.toLowerCase().contains(q)
    ).toList();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 拖拽条
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // 标题
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text(
            '选择音色',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // 搜索框
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _searchQuery = v),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '搜索音色…',
              hintStyle: const TextStyle(color: Colors.white30),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),
        // 音色列表
        Expanded(
          child: ListView.builder(
            controller: ScrollController(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            itemCount: _filtered.length,
            itemBuilder: (ctx, i) {
              final v = _filtered[i];
              final selected = v.voice == widget.selectedVoice;
              return _VoiceTile(
                option: v,
                selected: selected,
                onTap: () => widget.onVoiceSelected(v.voice),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _VoiceTile extends StatelessWidget {
  final TtsVoiceOption option;
  final bool selected;
  final VoidCallback onTap;

  const _VoiceTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xff635bff).withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? Border.all(color: const Color(0xff635bff), width: 1.5)
              : null,
        ),
        child: Row(
          children: [
            // 性别图标
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: option.gender == 'female'
                    ? const Color(0xffd63384).withValues(alpha: 0.2)
                    : const Color(0xff0d6efd).withValues(alpha: 0.2),
              ),
              child: Icon(
                option.gender == 'female' ? Icons.woman : Icons.man,
                color: option.gender == 'female'
                    ? const Color(0xffd63384)
                    : const Color(0xff0d6efd),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            // 音色名 + 描述
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.description,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            // 选中标记
            if (selected)
              const Icon(Icons.check_circle, color: Color(0xff635bff), size: 22),
          ],
        ),
      ),
    );
  }
}
