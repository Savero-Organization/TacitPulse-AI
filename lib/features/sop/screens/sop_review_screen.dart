// sop_review_screen.dart — layar review & edit draft SOP dari suara (GABUT-56..58).

import 'package:flutter/material.dart';

import '../../../core/sop/models/sop_draft_model.dart';
import '../../../core/theme/app_colors.dart';
import '../sop_knowledge_store.dart';
import '../widgets/step_editor_tile.dart';

/// Form interaktif untuk meninjau dan mengedit [SopDraftModel].
class SopReviewScreen extends StatefulWidget {
  const SopReviewScreen({
    super.key,
    required this.initialDraft,
    this.store,
  });

  final SopDraftModel initialDraft;

  /// Store offline; default [SqliteSopStore]. Di-inject untuk widget test.
  final SopStore? store;

  @override
  State<SopReviewScreen> createState() => _SopReviewScreenState();
}

class _SopReviewScreenState extends State<SopReviewScreen> {
  late SopDraftModel _draft;
  bool _saving = false;

  late final TextEditingController _title;
  late final TextEditingController _equipment;
  late final TextEditingController _category;
  late final TextEditingController _summary;
  late final TextEditingController _hazardInput;
  late final TextEditingController _toolInput;

  @override
  void initState() {
    super.initState();
    _draft = widget.initialDraft;
    _title = TextEditingController(text: _draft.title);
    _equipment = TextEditingController(text: _draft.equipment);
    _category = TextEditingController(text: _draft.category);
    _summary = TextEditingController(text: _draft.summary);
    _hazardInput = TextEditingController();
    _toolInput = TextEditingController();
  }

  @override
  void dispose() {
    _title.dispose();
    _equipment.dispose();
    _category.dispose();
    _summary.dispose();
    _hazardInput.dispose();
    _toolInput.dispose();
    super.dispose();
  }

  void _syncFromFields() {
    _draft = _draft.copyWith(
      title: _title.text,
      equipment: _equipment.text,
      category: _category.text,
      summary: _summary.text,
    );
  }

  void _setStep(int index, SopStep step) {
    final steps = List<SopStep>.of(_draft.steps);
    steps[index] = step;
    _renumber(steps);
    setState(() => _draft = _draft.copyWith(steps: steps));
  }

  void _deleteStep(int index) {
    final steps = List<SopStep>.of(_draft.steps)..removeAt(index);
    _renumber(steps);
    setState(() => _draft = _draft.copyWith(steps: steps));
  }

  void _insertStepBelow(int index) {
    final steps = List<SopStep>.of(_draft.steps)
      ..insert(index + 1, const SopStep(stepNumber: 0, action: ''));
    _renumber(steps);
    setState(() => _draft = _draft.copyWith(steps: steps));
  }

  void _renumber(List<SopStep> steps) {
    for (var i = 0; i < steps.length; i++) {
      steps[i] = steps[i].copyWith(stepNumber: i + 1);
    }
  }

  void _addHazard() {
    final value = _hazardInput.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _draft = _draft.copyWith(hazards: [..._draft.hazards, value]);
      _hazardInput.clear();
    });
  }

  void _removeHazard(int index) {
    setState(() {
      _draft = _draft.copyWith(
        hazards: List<String>.of(_draft.hazards)..removeAt(index),
      );
    });
  }

  void _addTool() {
    final value = _toolInput.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _draft = _draft.copyWith(requiredTools: [..._draft.requiredTools, value]);
      _toolInput.clear();
    });
  }

  void _removeTool(int index) {
    setState(() {
      _draft = _draft.copyWith(
        requiredTools: List<String>.of(_draft.requiredTools)..removeAt(index),
      );
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    _syncFromFields();
    final validSteps = _draft.steps
        .where((s) => s.action.trim().isNotEmpty)
        .toList(growable: true);

    if (_draft.title.trim().isEmpty || validSteps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Judul wajib diisi dan minimal 1 langkah valid'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    _renumber(validSteps);
    _draft = _draft.copyWith(steps: validSteps);

    try {
      final store = widget.store ?? SqliteSopStore();
      await store.saveSop(_draft);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SOP successfully saved to Knowledge Store'),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal menyimpan: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slateDark,
      appBar: AppBar(
        title: const Text('Review Draft SOP'),
        backgroundColor: AppColors.deepCharcoal,
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            children: [
              Container(
                key: const Key('sop_status_header'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.deepCharcoal,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined,
                        color: AppColors.industrialAmber),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Voice-Generated SOP Draft',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('sop_title_field'),
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'SOP Title',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _syncFromFields(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('sop_equipment_field'),
                controller: _equipment,
                decoration: const InputDecoration(
                  labelText: 'Equipment / Machinery',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _syncFromFields(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('sop_category_field'),
                controller: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _syncFromFields(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('sop_summary_field'),
                controller: _summary,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Procedure Summary',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _syncFromFields(),
              ),
              const SizedBox(height: 16),
              _chipSection(
                title: 'Potential Hazards',
                items: _draft.hazards,
                onRemove: _removeHazard,
                inputController: _hazardInput,
                onAdd: _addHazard,
                inputKey: const Key('hazard_input'),
                addKey: const Key('hazard_add'),
              ),
              const SizedBox(height: 16),
              _chipSection(
                title: 'Required Tools',
                items: _draft.requiredTools,
                onRemove: _removeTool,
                inputController: _toolInput,
                onAdd: _addTool,
                inputKey: const Key('tool_input'),
                addKey: const Key('tool_add'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Work Steps',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              ReorderableListView.builder(
                key: const Key('sop_steps_list'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _draft.steps.length,
                onReorderItem: (oldIndex, newIndex) {
                  final steps = List<SopStep>.of(_draft.steps);
                  final item = steps.removeAt(oldIndex);
                  steps.insert(newIndex, item);
                  _renumber(steps);
                  setState(() => _draft = _draft.copyWith(steps: steps));
                },
                itemBuilder: (context, index) {
                  final step = _draft.steps[index];
                  return StepEditorTile(
                    key: ValueKey('step_${step.stepNumber}_$index'),
                    step: step,
                    onChanged: (updated) => _setStep(index, updated),
                    onDelete: () => _deleteStep(index),
                    onInsertBelow: () => _insertStepBelow(index),
                    dragHandle: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Icon(Icons.drag_indicator,
                            color: AppColors.textMuted),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          if (_saving)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x88000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          key: const Key('sop_save_button'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_alt),
          label: const Text('Save to Knowledge Store'),
        ),
      ),
    );
  }

  Widget _chipSection({
    required String title,
    required List<String> items,
    required void Function(int) onRemove,
    required TextEditingController inputController,
    required VoidCallback onAdd,
    required Key inputKey,
    required Key addKey,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < items.length; i++)
              Chip(
                label: Text(items[i]),
                onDeleted: () => onRemove(i),
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: inputKey,
                controller: inputController,
                decoration: InputDecoration(
                  hintText: 'Tambah $title...',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => onAdd(),
              ),
            ),
            IconButton(
              key: addKey,
              icon: const Icon(Icons.add),
              onPressed: onAdd,
            ),
          ],
        ),
      ],
    );
  }
}
