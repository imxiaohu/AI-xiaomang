import 'package:flutter/material.dart';

enum TripoGenerationMode { textTo3D, imageTo3D, multiImageTo3D }

class TripoGenerationDialog extends StatefulWidget {
  final TripoGenerationMode initialMode;
  final Function(String input, TripoGenerationMode mode) onSubmit;

  const TripoGenerationDialog({
    super.key,
    this.initialMode = TripoGenerationMode.textTo3D,
    required this.onSubmit,
  });

  @override
  State<TripoGenerationDialog> createState() => _TripoGenerationDialogState();
}

class _TripoGenerationDialogState extends State<TripoGenerationDialog> {
  late TextEditingController _promptController;
  late TextEditingController _imgFront;
  late TextEditingController _imgLeft;
  late TextEditingController _imgBack;
  late TextEditingController _imgRight;
  late TripoGenerationMode _mode;

  /// 多图模式：各视角是否启用
  late List<bool> _imgEnabled;
  static const _viewLabels = ['前视角', '左视角', '后视角', '右视角'];

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _imgFront = TextEditingController();
    _imgLeft = TextEditingController();
    _imgBack = TextEditingController();
    _imgRight = TextEditingController();
    _mode = widget.initialMode;
    _imgEnabled = [true, true, true, true];
  }

  @override
  void dispose() {
    _promptController.dispose();
    _imgFront.dispose();
    _imgLeft.dispose();
    _imgBack.dispose();
    _imgRight.dispose();
    super.dispose();
  }

  void _submit() {
    switch (_mode) {
      case TripoGenerationMode.textTo3D:
        final prompt = _promptController.text.trim();
        if (prompt.isEmpty) {
          _showError('请输入提示词');
          return;
        }
        if (prompt.length > 1024) {
          _showError('提示词不能超过1024个字符');
          return;
        }
        widget.onSubmit(prompt, _mode);

      case TripoGenerationMode.imageTo3D:
        final url = _imgFront.text.trim();
        if (url.isEmpty) {
          _showError('请上传图片或输入图片URL');
          return;
        }
        widget.onSubmit(url, _mode);

      case TripoGenerationMode.multiImageTo3D:
        final ctrls = [_imgFront, _imgLeft, _imgBack, _imgRight];
        int count = 0;
        for (int i = 0; i < 4; i++) {
          if (_imgEnabled[i] && ctrls[i].text.trim().isNotEmpty) count++;
        }
        if (count < 2) {
          _showError('多图模式至少需要2张有效图片');
          return;
        }
        // 编码：enabled+有url → URL，否则 → null
        final encoded = <String?>[];
        for (int i = 0; i < 4; i++) {
          if (_imgEnabled[i]) {
            final url = ctrls[i].text.trim();
            encoded.add(url.isEmpty ? null : url);
          } else {
            encoded.add(null); // 用户禁用的视角
          }
        }
        widget.onSubmit(encoded.join('|'), _mode);
    }
    Navigator.of(context).pop();
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xff1e1e2e),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 680),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),
              _buildModeSelector(),
              const SizedBox(height: 16),
              if (_mode == TripoGenerationMode.textTo3D) _buildTextInput(),
              if (_mode == TripoGenerationMode.imageTo3D) _buildSingleImageInput(),
              if (_mode == TripoGenerationMode.multiImageTo3D) _buildMultiImageInput(),
              const SizedBox(height: 16),
              _buildQuotaWarning(),
              const SizedBox(height: 16),
              _buildButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(Icons.view_in_ar, color: Color(0xff635bff), size: 22),
        const SizedBox(width: 8),
        const Text(
          'AI 生成 3D 模型',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white54),
          onPressed: () => Navigator.of(context).pop(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  Widget _buildModeSelector() {
    final modes = [
      (TripoGenerationMode.textTo3D, '文生3D', Icons.text_fields),
      (TripoGenerationMode.imageTo3D, '单图生3D', Icons.image),
      (TripoGenerationMode.multiImageTo3D, '多图生3D', Icons.photo_library),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: modes.map((m) {
        final selected = _mode == m.$1;
        return ChoiceChip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(m.$3, size: 16, color: selected ? Colors.white : Colors.white54),
              const SizedBox(width: 4),
              Text(m.$2),
            ],
          ),
          selected: selected,
          selectedColor: const Color(0xff635bff),
          backgroundColor: const Color(0xff2a2a3e),
          labelStyle: TextStyle(color: selected ? Colors.white : Colors.white54, fontSize: 12),
          onSelected: (_) => setState(() => _mode = m.$1),
        );
      }).toList(),
    );
  }

  Widget _buildTextInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '提示词（描述你想生成的3D模型）',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 4),
        const Text(
          '支持中英文，最大1024个字符',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 3,
          maxLength: 1024,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: '例如：一只可爱的卡通风格的蓝色小猫',
            hintStyle: const TextStyle(color: Colors.white24),
            counterStyle: const TextStyle(color: Colors.white30, fontSize: 10),
            filled: true,
            fillColor: const Color(0xff2a2a3e),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xff635bff)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: ['一只猫', '一辆跑车', '一棵树', '机器人'].map((e) {
            return ActionChip(
              label: Text(e, style: const TextStyle(fontSize: 11)),
              backgroundColor: const Color(0xff2a2a3e),
              labelStyle: const TextStyle(color: Colors.white54),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: () => _promptController.text = e,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSingleImageInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '图片（公网URL）',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 4),
        const Text(
          '支持 JPEG/PNG，宽高20~6000像素，不超过20MB',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _imgFront,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'https://example.com/photo.jpg',
            hintStyle: const TextStyle(color: Colors.white24),
            prefixIcon: const Icon(Icons.link, color: Colors.white38, size: 18),
            filled: true,
            fillColor: const Color(0xff2a2a3e),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xff635bff)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMultiImageInput() {
    final ctrls = [_imgFront, _imgLeft, _imgBack, _imgRight];
    final hints = [
      'https://example.com/front.png',
      'https://example.com/left.png',
      'https://example.com/back.png',
      'https://example.com/right.png',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '多角度图片（2~4张，必须包含前视角）',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 4),
        const Text(
          '固定4个视角 [前·左·后·右]，不需要的视角点×禁用，不填则留空',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 10),
        ...List.generate(4, (i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildImageSlot(i, ctrls[i], hints[i]),
        )),
      ],
    );
  }

  Widget _buildImageSlot(int index, TextEditingController ctrl, String hint) {
    final enabled = _imgEnabled[index];
    return Row(
      children: [
        // 视角标签 + 启用开关
        GestureDetector(
          onTap: () {
            // 前视角不允许禁用
            if (index == 0) return;
            setState(() => _imgEnabled[index] = !_imgEnabled[index]);
          },
          child: Container(
            width: 72,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: index == 0
                  ? const Color(0xff635bff).withValues(alpha: 0.3)
                  : enabled
                      ? const Color(0xff635bff).withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: index == 0 || enabled
                    ? const Color(0xff635bff).withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                Text(
                  _viewLabels[index],
                  style: TextStyle(
                    color: index == 0 || enabled ? Colors.white70 : Colors.white30,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  index == 0 ? Icons.lock : (enabled ? Icons.check_circle : Icons.cancel),
                  size: 12,
                  color: index == 0 || enabled ? const Color(0xff635bff) : Colors.white30,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // URL 输入框
        Expanded(
          child: TextField(
            controller: ctrl,
            enabled: enabled,
            style: TextStyle(
              color: enabled ? Colors.white : Colors.white30,
              fontSize: 12,
            ),
            decoration: InputDecoration(
              hintText: enabled ? hint : '（已禁用）',
              hintStyle: const TextStyle(color: Colors.white54, fontSize: 11),
              prefixIcon: Icon(
                Icons.link,
                color: enabled ? Colors.white54 : Colors.white38,
                size: 14,
              ),
              filled: true,
              fillColor: const Color(0xff2a2a3e),
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xff635bff)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(
                  color: enabled
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.white.withValues(alpha: 0.03),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuotaWarning() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '每月限额3次生成',
                  style: TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 2),
                Text(
                  '3D生成约需2~5分钟。GLB链接有效期2小时，请及时下载。\n'
                  'task_id有效期24小时。',
                  style: TextStyle(color: Colors.amber, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Colors.white54)),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xff635bff),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _submit,
          child: const Text('开始生成'),
        ),
      ],
    );
  }
}
