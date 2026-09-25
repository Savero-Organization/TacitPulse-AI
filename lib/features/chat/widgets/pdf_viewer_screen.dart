import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/theme/app_colors.dart';
import 'bounding_box_overlay.dart';

/// Penampil PDF lokal (GABUT 40) dengan navigasi halaman, zoom/scroll,
/// dan highlight bounding box kutipan (GABUT 41) di halaman tujuan.
///
/// Renderer: `pdfrx` (PDFium) — support Android + Linux, membuka file
/// lokal, expose ukuran halaman, dan `PdfViewerController.goToPage`.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.filePath,
    this.initialPage = 1,
    this.highlightBox,
  });

  /// Path file PDF di perangkat.
  final String filePath;

  /// Nomor halaman tujuan (1-based).
  final int initialPage;

  /// Bounding box NORMALIZED 0..1 pada [initialPage]; null = tanpa highlight.
  final Rect? highlightBox;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();
  int _currentPage = 1;
  int _pageCount = 0;

  String get _title {
    final name = widget.filePath.split(RegExp(r'[/\\]')).last;
    return name.isEmpty ? 'Dokumen PDF' : name;
  }

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _controller.addListener(_syncPageFromController);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncPageFromController);
    super.dispose();
  }

  void _syncPageFromController() {
    if (!mounted) return;
    final page = _controller.isReady ? (_controller.pageNumber ?? _currentPage) : _currentPage;
    final count = _controller.isReady ? _controller.pageCount : _pageCount;
    if (page != _currentPage || count != _pageCount) {
      setState(() {
        _currentPage = page;
        _pageCount = count;
      });
    }
  }

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    _syncPageFromController();
    _focusHighlight();
  }

  /// Center-kan viewport ke bounding box highlight (koordinat dokumen 72dpi,
  /// top-left origin — sama orientasi dengan box normalized).
  void _focusHighlight() {
    final box = widget.highlightBox;
    if (box == null || !mounted || !_controller.isReady) return;
    final layouts = _controller.layout.pageLayouts;
    final index = widget.initialPage - 1;
    if (index < 0 || index >= layouts.length) return;
    final pageRect = layouts[index];
    final target = mapNormalizedBboxToPageRect(box, pageRect.size).translate(pageRect.left, pageRect.top);
    _controller.ensureVisible(target, margin: 24);
  }

  void _goToPage(int pageNumber) {
    if (!_controller.isReady) return;
    _controller.goToPage(pageNumber: pageNumber.clamp(1, _controller.pageCount));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slateDark,
      appBar: AppBar(
        title: Text(_title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Zoom out',
            icon: const Icon(Icons.zoom_out_rounded),
            onPressed: _controller.isReady ? () => _controller.zoomDown() : null,
          ),
          IconButton(
            tooltip: 'Zoom in',
            icon: const Icon(Icons.zoom_in_rounded),
            onPressed: _controller.isReady ? () => _controller.zoomUp() : null,
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: _pageBar(),
        ),
      ),
      body: PdfViewer.file(
        widget.filePath,
        controller: _controller,
        initialPageNumber: widget.initialPage < 1 ? 1 : widget.initialPage,
        params: PdfViewerParams(
          backgroundColor: AppColors.deepCharcoal,
          onViewerReady: _onViewerReady,
          onPageChanged: (_) => _syncPageFromController(),
          errorBannerBuilder: (context, error, stackTrace, documentRef) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Gagal memuat PDF:\n$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          ),
          pageOverlaysBuilder: (context, pageRectInViewer, page) {
            final box = widget.highlightBox;
            if (box == null || page.pageNumber != widget.initialPage) return const <Widget>[];
            return [
              BoundingBoxOverlay(boxes: [box], pageSize: pageRectInViewer.size),
            ];
          },
        ),
      ),
    );
  }

  Widget _pageBar() {
    return SizedBox(
      height: 34,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Halaman sebelumnya',
            icon: const Icon(Icons.chevron_left_rounded, color: AppColors.textPrimary, size: 22),
            onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
          ),
          Text(
            _pageCount > 0 ? 'Hal. $_currentPage / $_pageCount' : 'Hal. $_currentPage',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
          IconButton(
            tooltip: 'Halaman berikutnya',
            icon: const Icon(Icons.chevron_right_rounded, color: AppColors.textPrimary, size: 22),
            onPressed: _pageCount == 0 || _currentPage < _pageCount
                ? () => _goToPage(_currentPage + 1)
                : null,
          ),
        ],
      ),
    );
  }
}
