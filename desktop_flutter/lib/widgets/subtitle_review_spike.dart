import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class SubtitleReviewSpike extends StatefulWidget {
  const SubtitleReviewSpike({super.key});

  @override
  State<SubtitleReviewSpike> createState() => _SubtitleReviewSpikeState();
}

class _SubtitleReviewSpikeState extends State<SubtitleReviewSpike> {
  final _rows = List.generate(
    1000,
    (i) => SubtitleRow(
      index: i + 1,
      time: _timecode(i),
      text: '第 ${i + 1} 条字幕片段：这里用于 release 下滚动、选择、编辑和质量标记验证。',
      quality: i % 9 == 0 ? QualityMark.warn : QualityMark.ok,
    ),
  );
  int _selected = 0;
  late final TextEditingController _editor = TextEditingController(
    text: _rows.first.text,
  );

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() {
      _selected = index;
      _editor.text = _rows[index].text;
    });
  }

  void _saveText() {
    setState(() {
      _rows[_selected] = _rows[_selected].copyWith(text: _editor.text);
    });
  }

  void _toggleQuality() {
    final current = _rows[_selected].quality;
    setState(() {
      _rows[_selected] = _rows[_selected].copyWith(
        quality: current == QualityMark.ok ? QualityMark.warn : QualityMark.ok,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _rows[_selected];
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: ListView.builder(
            itemCount: _rows.length,
            itemExtent: 44,
            itemBuilder: (context, index) => _SubtitleTile(
              row: _rows[index],
              selected: index == _selected,
              onTap: () => _select(index),
            ),
          ),
        ),
        const SizedBox(width: T.s24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1000 条字幕审看小样', style: T.tSection),
              const SizedBox(height: T.s12),
              Text(
                '#${selected.index} · ${selected.time} · ${selected.quality.zh}',
                style: T.tCaption,
              ),
              const SizedBox(height: T.s12),
              TextField(
                controller: _editor,
                maxLines: 5,
                style: T.tBody,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: T.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(T.rMd),
                    borderSide: const BorderSide(color: T.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(T.rMd),
                    borderSide: const BorderSide(color: T.accent, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: T.s12),
              Row(
                children: [
                  _SmallAction(label: '保存文本', onTap: _saveText),
                  const SizedBox(width: T.s8),
                  _SmallAction(label: '切换质量标记', onTap: _toggleQuality),
                ],
              ),
              const SizedBox(height: T.s16),
              Text(
                'Phase A 用于 release 下观察滚动帧感、选中响应、文本编辑延迟和内存占用。',
                style: T.tCaption,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _timecode(int i) {
    final seconds = i * 4;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '00:$mm:$ss,000';
  }
}

enum QualityMark { ok, warn }

extension QualityMarkLabel on QualityMark {
  String get zh => switch (this) {
    QualityMark.ok => '正常',
    QualityMark.warn => '需复核',
  };
}

class SubtitleRow {
  const SubtitleRow({
    required this.index,
    required this.time,
    required this.text,
    required this.quality,
  });

  final int index;
  final String time;
  final String text;
  final QualityMark quality;

  SubtitleRow copyWith({String? text, QualityMark? quality}) {
    return SubtitleRow(
      index: index,
      time: time,
      text: text ?? this.text,
      quality: quality ?? this.quality,
    );
  }
}

class _SubtitleTile extends StatelessWidget {
  const _SubtitleTile({
    required this.row,
    required this.selected,
    required this.onTap,
  });

  final SubtitleRow row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final markColor = row.quality == QualityMark.ok ? T.ok : T.warn;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? T.accentSoft : null,
            border: const Border(bottom: BorderSide(color: T.line)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: T.s8),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: Text('#${row.index}', style: T.tCaption),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: markColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  row.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(color: T.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallAction extends StatefulWidget {
  const _SmallAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_SmallAction> createState() => _SmallActionState();
}

class _SmallActionState extends State<_SmallAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: T.accent),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(color: T.accentStrong),
          ),
        ),
      ),
    );
  }
}
