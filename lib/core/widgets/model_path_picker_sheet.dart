// ModelPathPickerSheet — modal bottom sheet untuk memilih file model
// `.gguf` dari sistem file user.
//
// Alur:
//   1. User memilih file via OS File Picker (`file_picker`) atau memasukkan
//      path manual.
//   2. File divalidasi real-time (GGUF magic + keluarga/ukuran target Qwen)
//      lewat [GgufValidator].
//   3. Bila valid → Simpan custom path ke SharedPreferences
//      (`ModelManager.setCustomModelPath`) lalu reload model.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../downloads/model_download_service.dart';
import '../theme/app_colors.dart';
import '../utils/gguf_validator.dart';
import '../utils/model_loader.dart';

/// Modal bottom sheet untuk pemilihan model on-device.
class ModelPathPickerSheet extends StatefulWidget {
  const ModelPathPickerSheet({super.key, this.onSaved});

  /// Dipanggil setelah custom path tersimpan (untuk reload LLM).
  final ValueChanged<String>? onSaved;

  /// Membuka bottom sheet. Mengembalikan path yang disimpan, atau null
  /// bila dibatalkan.
  static Future<String?> show(
    BuildContext context, {
    ValueChanged<String>? onSaved,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ModelPathPickerSheet(onSaved: onSaved),
    );
  }

  @override
  State<ModelPathPickerSheet> createState() => _ModelPathPickerSheetState();
}

enum _ValidationState { none, validating, valid, invalid }

class _ModelPathPickerSheetState extends State<ModelPathPickerSheet> {
  final TextEditingController _controller = TextEditingController();

  _ValidationState _state = _ValidationState.none;
  GgufValidationResult? _result;
  bool _saved = false;
  String? _pickerHint;
  double _modelSizeMb = ModelManager.defaultModelSizeMb;

  @override
  void initState() {
    super.initState();
    _loadCurrentCustomPath();
    _resolveRemoteSize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentCustomPath() async {
    final path = await ModelManager.getCustomModelPath();
    if (path == null || path.isEmpty || !mounted) return;
    final normalized = GgufValidator.normalizePath(path);
    _controller.text = normalized;
    await _validate(normalized);
  }

  /// Resolve ukuran model remote (via HEAD CDN HF) lalu perbarui label tombol
  /// unduh. Saat offline / gagal, label tetap memakai [defaultModelSizeMb].
  Future<void> _resolveRemoteSize() async {
    final resolvedSize = await ModelManager.fetchRemoteModelSize();
    if (resolvedSize != null && mounted) {
      setState(() {
        _modelSizeMb = resolvedSize;
      });
    }
  }

  /// Buka file picker OS. Resilien terhadap lingkungan tanpa portal:
  /// setiap kegagalan ([PlatformException] mis. Hyprland/WM minimal,
  /// [UnimplementedError], atau error lain) atau cancel → TIDAK crash /
  /// membekukan UI, cukup tampilkan hint manual entry.
  Future<void> _pickFile() async {
    final String? path;
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['gguf'],
      );
      path = picked?.path;
    } on PlatformException {
      _setPickerHint(
        'File picker OS tidak merespon (common di Hyprland/WM minimal). '
        'Silakan ketik path absolute secara manual.',
      );
      return;
    } on UnimplementedError {
      _setPickerHint(
        'File picker belum didukung di platform ini. '
        'Silakan ketik path absolute secara manual.',
      );
      return;
    } catch (_) {
      _setPickerHint(
        'File picker OS gagal dibuka (portal tidak tersedia?). '
        'Silakan ketik path absolute secara manual.',
      );
      return;
    }

    if (path == null || path.isEmpty) {
      _setPickerHint(
        'Tidak ada file dipilih. Silakan ketik path absolute secara '
        'manual, atau coba buka picker lagi.',
      );
      return;
    }
    _clearPickerHint();
    _controller.text = path;
    await _validate(path);
  }

  /// Validasi real-time. Input dinormalisasi dulu via
  /// [GgufValidator.normalizePath] sehingga `~/...`, `home/user/...`, dan
  /// `/home/user/...` semua merujuk ke file yang sama. Rekursi onChanged
  /// dari update controller diakhiri saat path sudah ternormalisasi.
  Future<void> _validate(String rawPath) async {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _state = _ValidationState.none;
        _result = null;
        _pickerHint = null;
      });
      return;
    }
    final normalized = GgufValidator.normalizePath(trimmed);
    if (normalized != _controller.text) {
      _controller.text = normalized;
      return; // onChanged akan re-masuk dengan path ternormalisasi.
    }
    setState(() {
      _state = _ValidationState.validating;
      _result = null;
    });
    final result = await GgufValidator.validateFile(normalized);
    if (!mounted) return;
    setState(() {
      _result = result;
      _state = result.validForUse
          ? _ValidationState.valid
          : _ValidationState.invalid;
    });
  }

  void _setPickerHint(String hint) {
    if (!mounted) return;
    setState(() => _pickerHint = hint);
  }

  void _clearPickerHint() {
    if (!mounted || _pickerHint == null) return;
    setState(() => _pickerHint = null);
  }

  // -------------------------------------------------------------------------
  // In-App Downloader (mirror HuggingFace CDN) — dijalankan via
  // [ModelDownloadService] GLOBAL sehingga unduhan TIDAK terikat hidup matinya
  // sheet ini: user boleh menutup panel / pindah layar, unduhan tetap jalan &
  // bisa dilanjutkan dari status bar (pause/resume didukung, resume = `wget -c`).
  // -------------------------------------------------------------------------

  String? _downloadError;

  ModelDownloadService get _service => ModelDownloadService.instance;

  Future<void> _startDownload() async {
    if (_service.isDownloading) return;
    setState(() => _downloadError = null);
    await _service.startDownload(
      url: ModelManager.defaultModelDownloadUrl,
      fileName: ModelManager.defaultModelName,
    );
    if (!mounted) return;
    final p = _service.progress;
    if (p.phase == DownloadPhase.completed) {
      await _finalizeDownloadedModel(p.resultPath);
    }
  }

  /// Unduhan selesai di latar belakang: validasi GGUF, simpan path,
  /// panggil [onSaved], tutup sheet.
  Future<void> _finalizeDownloadedModel(String? path) async {
    if (path == null) return;
    final result = await GgufValidator.validateFile(path);
    if (!mounted) return;

    if (result.validForUse) {
      setState(() {
        _downloadError = null;
        _saved = true;
        _state = _ValidationState.valid;
        _result = result;
        _controller.text = path;
      });
      widget.onSaved?.call(path);
      Navigator.of(context).pop(path);
    } else {
      setState(() {
        _downloadError = 'File terunduh tidak valid: '
            '${result.errorMessage ?? 'GGUF tidak sesuai target'}';
      });
    }
  }

  Widget _buildDownloadSection() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final p = _service.progress;
        final downloading = p.phase == DownloadPhase.downloading;
        final paused = p.phase == DownloadPhase.paused;

        if (downloading || paused) {
          final mb = 1024 * 1024;
          final doneMb = (p.bytesDownloaded / mb).toStringAsFixed(1);
          final totalText = p.totalBytes > 0
              ? (p.totalBytes / mb).toStringAsFixed(1)
              : '…';
          final speed = p.speedBytesPerSecond > 0
              ? ' · ${(p.speedBytesPerSecond / mb).toStringAsFixed(1)} MB/s'
              : '';
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: AppColors.slateDark,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.surfaceBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      paused
                          ? Icons.pause_circle_outline_rounded
                          : Icons.cloud_download_outlined,
                      color: paused
                          ? AppColors.warning
                          : AppColors.cyanAccent,
                      size: 15,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        paused
                            ? 'Unduhan dijeda — lanjut kapan saja'
                            : 'Mengunduh ${ModelManager.defaultModelName} …',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: paused
                          ? 'Lanjutkan'
                          : 'Jeda unduhan',
                      onPressed: paused ? _service.resume : _service.pause,
                      icon: Icon(
                        paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        color: AppColors.warning,
                        size: 20,
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                    IconButton(
                      tooltip: 'Batalkan unduhan',
                      onPressed: _service.cancel,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.textMuted,
                        size: 18,
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: p.fraction,
                    minHeight: 6,
                    backgroundColor: AppColors.slateMuted,
                    valueColor: AlwaysStoppedAnimation(
                      paused ? AppColors.warning : AppColors.industrialAmber,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  paused
                      ? '$doneMb MB tersimpan — unduhan berlanjut di '
                          'latar belakang, bisa resume'
                      : '$doneMb MB / $totalText$speed',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Panel ini boleh ditutup — unduhan tetap berjalan & '
                  'bisa dilanjutkan dari status bar di atas.',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          );
        }

        final error = _downloadError ?? p.errorMessage;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.slateDark,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.surfaceBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tidak punya file model? Unduh otomatis dari mirror '
                'HuggingFace (CDN). Bisa lanjut di latar belakang sambil '
                'mengerjakan hal lain.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _startDownload,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.industrialAmber,
                    foregroundColor: AppColors.slateDark,
                    minimumSize: const Size.fromHeight(38),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(
                    'Unduh Otomatis dari Server '
                    '(${_modelSizeMb.toStringAsFixed(1)} MB)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveAndClose() async {
    final path = GgufValidator.normalizePath(_controller.text);
    if (path.isEmpty || _state != _ValidationState.valid || _result == null) {
      return;
    }
    await ModelManager.setCustomModelPath(path);
    if (!mounted) return;
    setState(() => _saved = true);
    widget.onSaved?.call(path);
    Navigator.of(context).pop(path);
  }

  Future<void> _clearSelection() async {
    await ModelManager.setCustomModelPath(null);
    if (!mounted) return;
    _controller.clear();
    setState(() {
      _state = _ValidationState.none;
      _result = null;
      _pickerHint = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _state == _ValidationState.valid && _result != null && !_service.isDownloading;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.deepCharcoal,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.slateMuted,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Row(
              children: [
                Icon(Icons.model_training_rounded,
                    color: AppColors.cyanAccent, size: 20),
                SizedBox(width: 8),
                Text(
                  'Pilih File Model (.gguf)',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Harus berupa ${GgufValidator.targetModelLabel} '
              '(arsitektur qwen2/qwen3, ukuran 0.8B/0.5B).',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              onChanged: _validate,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText:
                    'Klik icon folder untuk memilih file, atau ketik absolute path di sini…',
                hintStyle:
                    const TextStyle(color: AppColors.textMuted, fontSize: 12),
                isDense: true,
                filled: true,
                fillColor: AppColors.slateDark,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                // Ikon KIRI: folder → langsung membuka OS File Explorer.
                prefixIcon: SizedBox(
                  width: 42,
                  child: IconButton(
                    tooltip: 'Buka File Explorer OS',
                    onPressed: _pickFile,
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.folder_open_rounded,
                        size: 18, color: AppColors.textSecondary),
                  ),
                ),
                // Ikon KANAN: checkmark → validasi path yang diketik manual.
                suffixIcon: IconButton(
                  tooltip: 'Validasi Path Teks',
                  onPressed: () => _validate(_controller.text),
                  icon: const Icon(Icons.fact_check_rounded,
                      color: AppColors.cyanAccent, size: 20),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: AppColors.surfaceBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: AppColors.surfaceBorder),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_pickerHint != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: AppColors.warning, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _pickerHint!,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 11.5, height: 1.35),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            _ValidationFeedback(state: _state, result: _result),
            const SizedBox(height: 12),
            _buildDownloadSection(),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _clearSelection,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    side: const BorderSide(color: AppColors.surfaceBorder),
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                  label: const Text('Gunakan default',
                      style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canSave ? _saveAndClose : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.industrialAmber,
                      foregroundColor: AppColors.slateDark,
                      padding:
                          const EdgeInsets.symmetric(vertical: 12),
                      disabledBackgroundColor:
                          AppColors.slateMuted.withValues(alpha: 0.4),
                    ),
                    icon: _saved
                        ? const Icon(Icons.check_rounded, size: 18)
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(
                      _saved ? 'Tersimpan' : 'Simpan & Muat Model',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Feedback validasi real-time (check hijau / warning / error merah).
class _ValidationFeedback extends StatelessWidget {
  const _ValidationFeedback({required this.state, required this.result});

  final _ValidationState state;
  final GgufValidationResult? result;

  @override
  Widget build(BuildContext context) {
    if (state == _ValidationState.none) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.slateDark,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline_rounded,
                color: AppColors.textMuted, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Belum ada file dipilih. Model akan dicari di storage standar '
                '& P2P mesh cache bila dilewati.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (state == _ValidationState.validating) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.slateDark,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.cyanAccent,
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Memvalidasi GGUF header…',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      );
    }

    final r = result;
    if (r == null) return const SizedBox.shrink();

    if (state == _ValidationState.valid) {
      return _feedback(
        AppColors.success,
        Icons.check_circle_rounded,
        'Model valid ✓  ${GgufValidator.targetModelLabel}\n'
        '${r.architecture ?? ''}${r.modelName == null ? '' : ' · ${r.modelName}'}',
      );
    }

    // invalid
    final isGguf = r.isValidGguf;
    return _feedback(
      isGguf ? AppColors.warning : AppColors.danger,
      isGguf
          ? Icons.warning_amber_rounded
          : Icons.error_rounded,
      r.errorMessage ?? 'File tidak valid.',
    );
  }

  Widget _feedback(Color color, IconData icon, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}