// step_editor_tile.dart — baris editor satu SopStep (GABUT-57).

import 'package:flutter/material.dart';

import '../../../core/sop/models/sop_draft_model.dart';
import '../../../core/theme/app_colors.dart';

/// Tile editor untuk satu langkah kerja: action + safetyNote bisa diedit,
/// langkah bisa dihapus atau disisipkan langkah baru setelahnya.
class StepEditorTile extends StatefulWidget {
  const StepEditorTile({
    super.key,
    required this.step,
    required this.onChanged,
    required this.onDelete,
    required this.onInsertBelow,
    this.dragHandle,
  });

  final SopStep step;
  final ValueChanged<SopStep> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onInsertBelow;
  final Widget? dragHandle;

  @override
  State<StepEditorTile> createState() => _StepEditorTileState();
}

class _StepEditorTileState extends State<StepEditorTile> {
  late final TextEditingController _actionController;
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _actionController = TextEditingController(text: widget.step.action);
    _noteController = TextEditingController(text: widget.step.safetyNote ?? '');
  }

  @override
  void didUpdateWidget(covariant StepEditorTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step != widget.step) {
      if (_actionController.text != widget.step.action) {
        _actionController.text = widget.step.action;
      }
      final note = widget.step.safetyNote ?? '';
      if (_noteController.text != note) {
        _noteController.text = note;
      }
    }
  }

  @override
  void dispose() {
    _actionController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _emit() {
    final note = _noteController.text.trim();
    widget.onChanged(widget.step.copyWith(
      action: _actionController.text,
      safetyNote: note.isEmpty ? null : note,
      clearSafetyNote: note.isEmpty,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.deepCharcoal,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.dragHandle != null) widget.dragHandle!,
                Text(
                  'Langkah ${widget.step.stepNumber}',
                  style: const TextStyle(
                    color: AppColors.industrialAmber,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: Key('step_insert_${widget.step.stepNumber}'),
                  tooltip: 'Tambah langkah di bawah',
                  icon: const Icon(Icons.add_circle_outline,
                      color: AppColors.cyanAccent),
                  onPressed: widget.onInsertBelow,
                ),
                IconButton(
                  key: Key('step_delete_${widget.step.stepNumber}'),
                  tooltip: 'Hapus langkah',
                  icon: const Icon(Icons.delete_outline,
                      color: AppColors.danger),
                  onPressed: widget.onDelete,
                ),
              ],
            ),
            TextFormField(
              key: Key('step_action_${widget.step.stepNumber}'),
              controller: _actionController,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'Instruksi aksi',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _emit(),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: Key('step_note_${widget.step.stepNumber}'),
              controller: _noteController,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'Catatan keselamatan (opsional)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _emit(),
            ),
          ],
        ),
      ),
    );
  }
}
