import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../core/downloads/model_download_service.dart';
import '../../core/rag/pdf_ingest_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/model_path_picker_sheet.dart';
import '../../core/widgets/profile_app_bar_action.dart';
import '../../core/widgets/responsive_shell.dart';
import '../../core/widgets/widgets.dart';
import 'cubit/chat_cubit.dart';
import 'widgets/message_bubble.dart';
import 'widgets/voice_record_button.dart';

/// Knowledge Chat & Agentic RAG UI (Split-View Explorer Sidebar for Desktop).
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(create: (ctx) => ChatCubit(), child: const _ChatView());
  }
}

class _ChatView extends StatefulWidget {
  const _ChatView();

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  final TextEditingController _controller = TextEditingController();

  // State Riwayat Chat
  final List<String> _chatSessions = [
    'Cold Start Kompresor GA75',
    'Anomali Pressure Switch AA-221',
    'Maintenance Boiler Shift A',
  ];
  int _activeSessionIndex = 0;

  // State List Berkas SOP / Knowledge Base
  late List<_SourceDoc> _sourceDocsList;
  late Set<String> _selectedDocs;

  @override
  void initState() {
    super.initState();
    _sourceDocsList = List<_SourceDoc>.from(_defaultSourceDocs);
    _selectedDocs = {for (final d in _sourceDocsList) d.name};

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ChatCubit>().init();
    });

    // Unduhan model latar belakang selesai (di tab mana pun) → reload LLM
    // otomatis. reloadModel coalescing di ChatCubit mencegah reload ganda
    // (sumber ganda: sheet + listener ini) saat sheet masih terbuka.
    ModelDownloadService.instance.addListener(_onDownloadServiceChanged);
  }

  @override
  void dispose() {
    ModelDownloadService.instance.removeListener(_onDownloadServiceChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onDownloadServiceChanged() {
    final p = ModelDownloadService.instance.progress;
    if (p.phase != DownloadPhase.completed || p.resultPath == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ChatCubit>().reloadModel();
    });
  }

  void _send(BuildContext context) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    context.read<ChatCubit>().startStreaming(text);
    FocusScope.of(context).unfocus();
  }

  void _addNewSession() {
    context.read<ChatCubit>().clearChat();
    setState(() {
      _chatSessions.insert(0, 'Obrolan Baru ${_chatSessions.length + 1}');
      _activeSessionIndex = 0;
    });
  }

  void _deleteSession(int index) {
    if (index < 0 || index >= _chatSessions.length) return;
    setState(() {
      _chatSessions.removeAt(index);
      if (_chatSessions.isEmpty) {
        _chatSessions.add('Obrolan Baru');
        _activeSessionIndex = 0;
        context.read<ChatCubit>().clearChat();
      } else if (_activeSessionIndex >= _chatSessions.length) {
        _activeSessionIndex = _chatSessions.length - 1;
      }
    });
  }

  /// Impor PDF → ekstraksi teks + bbox per halaman → chunk 250-500 token →
  /// embedding lokal (GABUT-22) → SQLite vector store. Progres & error
  /// ditampilkan lewat SnackBar.
  Future<void> _importDoc(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Pilih PDF',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final path = picked.isEmpty ? null : picked.first.path;
    if (path == null || !mounted) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Parsing ${p.basename(path)} → chunking → embedding lokal…',
          ),
          // Ditutup saat selesai/gagal (lihat bawah).
          duration: const Duration(minutes: 5),
        ),
      );

    try {
      final chunkCount = await ingestPdf(path);
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            backgroundColor: AppColors.success,
            content: Text(
              chunkCount == 0
                  ? 'PDF tanpa lapisan teks (scan?) — tidak ada chunk tersimpan.'
                  : '$chunkCount chunk tersimpan di SQLite Vector Store.',
            ),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            backgroundColor: AppColors.danger,
            content: Text('Gagal import PDF: $error'),
          ),
        );
    }
  }

  /// Buka Model Path Picker Sheet; setelah custom path tersimpan, reload LLM.
  /// Bila engine Native (C-API llama.cpp) gagal memuat model dari file yang
  /// valid, tampilkan SnackBar merah berisi detail error native.
  Future<void> _openModelPicker(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await ModelPathPickerSheet.show(
      context,
      onSaved: (_) async {
        final cubit = context.read<ChatCubit>();
        await cubit.reloadModel();
        if (!mounted) return;
        if (!cubit.state.isModelLoaded) {
          final detail = cubit.startupError ??
              'model tidak ditemukan / tidak dapat dimuat';
          messenger.showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              elevation: 4,
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.all(16),
              content: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.deepCharcoal,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.6),
                    width: 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.danger,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Gagal Memuat Engine LLM Native',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$detail\nPastikan RAM mencukupi.',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      },
    );
  }

  void _toggleDoc(_SourceDoc doc) {
    setState(() {
      if (!_selectedDocs.add(doc.name)) {
        _selectedDocs.remove(doc.name);
      }
    });
  }

  void _selectAllDocs() {
    setState(() {
      _selectedDocs = {for (final d in _sourceDocsList) d.name};
    });
  }

  void _deselectAllDocs() {
    setState(() {
      _selectedDocs.clear();
    });
  }

  void _deleteDoc(_SourceDoc doc) {
    setState(() {
      _selectedDocs.remove(doc.name);
      _sourceDocsList.removeWhere((d) => d.name == doc.name);
    });
  }

  void _openSidebarSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: AppColors.deepCharcoal,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              top: false,
              child: _ExplorerSidebar(
                sessions: _chatSessions,
                activeSessionIndex: _activeSessionIndex,
                onSelectSession: (idx) {
                  setState(() => _activeSessionIndex = idx);
                  Navigator.pop(context);
                },
                onNewSession: () {
                  _addNewSession();
                  Navigator.pop(context);
                },
                onDeleteSession: _deleteSession,
                docs: _sourceDocsList,
                selectedDocs: _selectedDocs,
                onToggleDoc: _toggleDoc,
                onSelectAllDocs: _selectAllDocs,
                onDeselectAllDocs: _deselectAllDocs,
                onImportDoc: () => _importDoc(context),
                onDeleteDoc: _deleteDoc,
                scrollController: scrollController,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatCubit, ChatState>(
      builder: (context, state) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= kDesktopBreakpoint;
            final workspace = _buildWorkspace(context, state, isDesktop: isDesktop);

            if (isDesktop) {
              return Scaffold(
                backgroundColor: AppColors.slateDark,
                body: Row(
                  children: [
                    SizedBox(
                      width: 280,
                      child: _ExplorerSidebar(
                        sessions: _chatSessions,
                        activeSessionIndex: _activeSessionIndex,
                        onSelectSession: (idx) => setState(() => _activeSessionIndex = idx),
                        onNewSession: _addNewSession,
                        onDeleteSession: _deleteSession,
                        docs: _sourceDocsList,
                        selectedDocs: _selectedDocs,
                        onToggleDoc: _toggleDoc,
                        onSelectAllDocs: _selectAllDocs,
                        onDeselectAllDocs: _deselectAllDocs,
                        onImportDoc: () => _importDoc(context),
                        onDeleteDoc: _deleteDoc,
                      ),
                    ),
                    Container(width: 1, color: AppColors.surfaceBorder),
                    Expanded(child: workspace),
                  ],
                ),
              );
            }

            return Scaffold(
              appBar: AppBar(
                title: const Text('Knowledge Chat'),
                actions: [
                  IconButton(
                    onPressed: () => _openSidebarSheet(context),
                    tooltip: 'Explorer (Sesi & SOP)',
                    icon: const Icon(
                      Icons.folder_copy_outlined,
                      color: AppColors.cyanAccent,
                    ),
                  ),
                  const ProfileAppBarAction(),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _modelBadge(state),
                  ),
                ],
              ),
              body: workspace,
            );
          },
        );
      },
    );
  }

  Widget _buildWorkspace(BuildContext context, ChatState state, {required bool isDesktop}) {
    return Column(
      children: [
        if (isDesktop)
          _WorkspaceHeader(
            sessionTitle: _chatSessions.isNotEmpty
                ? _chatSessions[_activeSessionIndex]
                : 'Obrolan Baru',
            modelBadge: _modelBadge(state),
          ),
        if (state.status == ChatStatus.recording)
          const _RecordingBanner()
        else if (state.status == ChatStatus.streaming)
          const _StreamingBanner(),
        if (!state.isModelLoaded)
          _MissingModelBanner(onPickModel: () => _openModelPicker(context)),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            itemCount: state.messages.length,
            itemBuilder: (context, i) => MessageBubble(message: state.messages[i]),
          ),
        ),
        _Composer(
          controller: _controller,
          isRecording: state.status == ChatStatus.recording,
          isStreaming: state.status == ChatStatus.streaming,
          onAttach: () => _importDoc(context),
          onSend: () => _send(context),
          onStop: () => context.read<ChatCubit>().stopStreaming(),
          onVoiceStart: () => context.read<ChatCubit>().startVoiceRecording(),
          onVoiceStop: () => context.read<ChatCubit>().stopVoiceRecording(),
        ),
      ],
    );
  }

  Widget _modelBadge(ChatState state) {
    final online = state.isModelLoaded && state.hallucinationGuard;
    return Tooltip(
      message: 'Ketuk untuk memilih file model .gguf',
      child: InkWell(
        onTap: () => _openModelPicker(context),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.slateMuted.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.surfaceBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PulseDot(
                color: online ? AppColors.success : AppColors.warning,
                size: 7,
              ),
              const SizedBox(width: 6),
              const Text(
                'Qwen 3.5-0.8B',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header Desktop Workspace
class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.sessionTitle,
    required this.modelBadge,
  });

  final String sessionTitle;
  final Widget modelBadge;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.deepCharcoal,
        border: Border(bottom: BorderSide(color: AppColors.surfaceBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(
                  Icons.chat_bubble_outline_rounded,
                  color: AppColors.cyanAccent,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    sessionTitle,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              modelBadge,
              const SizedBox(width: 10),
              const ProfileAppBarAction(),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Explorer Sidebar Component (Filter, Accordion & Batch Management)
// ---------------------------------------------------------------------------

class _SourceDoc {
  const _SourceDoc(this.name, this.kind);

  final String name;
  final String kind;

  IconData get icon => kind == 'LOG'
      ? Icons.text_snippet_rounded
      : Icons.picture_as_pdf_rounded;

  Color get color => kind == 'LOG'
      ? AppColors.industrialAmber
      : AppColors.cyanAccent;
}

const _defaultSourceDocs = [
  _SourceDoc('SOP_Kompresor_Screw.pdf', 'PDF'),
  _SourceDoc('SOP_Cold_Start_Boiler.pdf', 'PDF'),
  _SourceDoc('Log_Anomali_Line2.log', 'LOG'),
  _SourceDoc('Worklog_Shift_A12.txt', 'LOG'),
];

class _ExplorerSidebar extends StatefulWidget {
  const _ExplorerSidebar({
    required this.sessions,
    required this.activeSessionIndex,
    required this.onSelectSession,
    required this.onNewSession,
    required this.onDeleteSession,
    required this.docs,
    required this.selectedDocs,
    required this.onToggleDoc,
    required this.onSelectAllDocs,
    required this.onDeselectAllDocs,
    required this.onImportDoc,
    required this.onDeleteDoc,
    this.scrollController,
  });

  final List<String> sessions;
  final int activeSessionIndex;
  final ValueChanged<int> onSelectSession;
  final VoidCallback onNewSession;
  final ValueChanged<int> onDeleteSession;

  final List<_SourceDoc> docs;
  final Set<String> selectedDocs;
  final ValueChanged<_SourceDoc> onToggleDoc;
  final VoidCallback onSelectAllDocs;
  final VoidCallback onDeselectAllDocs;
  final VoidCallback onImportDoc;
  final ValueChanged<_SourceDoc> onDeleteDoc;
  final ScrollController? scrollController;

  @override
  State<_ExplorerSidebar> createState() => _ExplorerSidebarState();
}

class _ExplorerSidebarState extends State<_ExplorerSidebar> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  bool _isChatExpanded = true;
  bool _isKnowledgeExpanded = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredSessions = widget.sessions
        .asMap()
        .entries
        .where((entry) =>
            entry.value.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    final filteredDocs = widget.docs
        .where((doc) =>
            doc.name.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    final allDocsSelected = widget.docs.isNotEmpty &&
        widget.selectedDocs.length == widget.docs.length;

    return Container(
      color: AppColors.deepCharcoal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header & Quick Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'EXPLORER',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onNewSession,
                      tooltip: 'Chat Baru',
                      icon: const Icon(
                        Icons.add_comment_outlined,
                        size: 18,
                        color: AppColors.cyanAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Cari SOP / Chat...',
                    hintStyle: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11),
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.slateMuted.withValues(alpha: 0.3),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? InkWell(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            child: const Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: AppColors.surfaceBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: AppColors.surfaceBorder),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.surfaceBorder),

          // Body Accordion
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: EdgeInsets.zero,
              children: [
                // SECTION 1: RIWAYAT CHAT
                _CollapsibleSectionHeader(
                  title: 'RIWAYAT CHAT (${filteredSessions.length})',
                  isExpanded: _isChatExpanded,
                  onToggleExpand: () =>
                      setState(() => _isChatExpanded = !_isChatExpanded),
                  actionIcon: Icons.add_rounded,
                  actionTooltip: 'Sesi Baru',
                  onAction: widget.onNewSession,
                ),
                if (_isChatExpanded) ...[
                  if (filteredSessions.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        'Tidak ada sesi chat.',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 11),
                      ),
                    )
                  else
                    for (final entry in filteredSessions)
                      _SessionTile(
                        title: entry.value,
                        isActive: entry.key == widget.activeSessionIndex,
                        onTap: () => widget.onSelectSession(entry.key),
                        onDelete: () => widget.onDeleteSession(entry.key),
                      ),
                ],

                const Divider(height: 16, color: AppColors.surfaceBorder),

                // SECTION 2: KNOWLEDGE BASE (SQLite DB)
                _CollapsibleSectionHeader(
                  title: 'KNOWLEDGE BASE (${filteredDocs.length})',
                  isExpanded: _isKnowledgeExpanded,
                  onToggleExpand: () => setState(
                      () => _isKnowledgeExpanded = !_isKnowledgeExpanded),
                  actionIcon: Icons.add_circle_outline_rounded,
                  actionTooltip: 'Import SOP/Log Baru',
                  onAction: widget.onImportDoc,
                  extraAction: InkWell(
                    onTap: allDocsSelected
                        ? widget.onDeselectAllDocs
                        : widget.onSelectAllDocs,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Text(
                        allDocsSelected ? 'Bersihkan' : 'Pilih Semua',
                        style: const TextStyle(
                          color: AppColors.cyanAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_isKnowledgeExpanded) ...[
                  if (filteredDocs.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        'Tidak ada berkas SOP.',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 11),
                      ),
                    )
                  else
                    for (final doc in filteredDocs)
                      _SourceDocTile(
                        doc: doc,
                        isSelected: widget.selectedDocs.contains(doc.name),
                        onToggle: () => widget.onToggleDoc(doc),
                        onDelete: () => widget.onDeleteDoc(doc),
                      ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleSectionHeader extends StatelessWidget {
  const _CollapsibleSectionHeader({
    required this.title,
    required this.isExpanded,
    required this.onToggleExpand,
    required this.onAction,
    this.actionTooltip = 'Tambah',
    this.actionIcon = Icons.add_rounded,
    this.extraAction,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onAction;
  final String actionTooltip;
  final IconData actionIcon;
  final Widget? extraAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 4),
      child: Row(
        children: [
          InkWell(
            onTap: onToggleExpand,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Icon(
                isExpanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onToggleExpand,
              child: Text(
                title,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          ?extraAction,
          const SizedBox(width: 4),
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Icon(actionIcon, size: 15, color: AppColors.cyanAccent),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.title,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  final String title;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: isActive
            ? AppColors.slateMuted.withValues(alpha: 0.5)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: isActive
              ? BorderSide(color: AppColors.cyanAccent.withValues(alpha: 0.4))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias, // Keeps tap ripples inside the rounded corners
        child: ListTile(
          dense: true,
          onTap: onTap,
          contentPadding: const EdgeInsets.only(left: 10, right: 4),
          leading: Icon(
            Icons.chat_bubble_outline_rounded,
            size: 15,
            color: isActive ? AppColors.cyanAccent : AppColors.textSecondary,
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
              fontSize: 12,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          trailing: IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 15,
              color: AppColors.textMuted,
            ),
            tooltip: 'Hapus Sesi',
            onPressed: onDelete,
          ),
        ),
      ),
    );
  }
}

class _SourceDocTile extends StatelessWidget {
  const _SourceDocTile({
    required this.doc,
    required this.isSelected,
    required this.onToggle,
    required this.onDelete,
  });

  final _SourceDoc doc;
  final bool isSelected;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.slateMuted.withValues(alpha: 0.2)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: isSelected,
                onChanged: (_) => onToggle(),
                activeColor: AppColors.industrialAmber,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(width: 6),
            Icon(doc.icon, color: doc.color, size: 15),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: onToggle,
                child: Text(
                  doc.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        isSelected ? AppColors.textPrimary : AppColors.textMuted,
                    fontSize: 12,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 15, color: AppColors.textMuted),
              tooltip: 'Hapus dari Knowledge Base',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Banners + Input Composer
// ---------------------------------------------------------------------------

class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
      color: AppColors.danger.withValues(alpha: 0.14),
      child: const Row(
        children: [
          PulseDot(color: AppColors.danger),
          SizedBox(width: 8),
          Text(
            'Merekam suara teknisi · whisper.cpp on-device',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StreamingBanner extends StatelessWidget {
  const _StreamingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
      color: AppColors.cyanAccent.withValues(alpha: 0.12),
      child: const Row(
        children: [
          PulseDot(color: AppColors.cyanAccent),
          SizedBox(width: 8),
          Text(
            'Streaming token · llama.cpp (Qwen 3.5-0.8B Q4_K_M)',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Banner saat model belum tersedia — menawarkan Model Path Picker
/// (tidak crash / tidak melempar error saat model hilang).
class _MissingModelBanner extends StatelessWidget {
  const _MissingModelBanner({required this.onPickModel});

  final VoidCallback onPickModel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
      color: AppColors.warning.withValues(alpha: 0.14),
      child: Row(
        children: [
          const PulseDot(color: AppColors.warning),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Model Qwen 3.5-0.8B belum tersedia. Chat berjalan mode demo.',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onPickModel,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: const Text(
              'Pilih File Model',
              style: TextStyle(
                color: AppColors.industrialAmber,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isRecording,
    required this.isStreaming,
    required this.onAttach,
    required this.onSend,
    required this.onStop,
    required this.onVoiceStart,
    required this.onVoiceStop,
  });

  final TextEditingController controller;
  final bool isRecording;
  final bool isStreaming;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onVoiceStart;
  final VoidCallback onVoiceStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.surfaceBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            onPressed: onAttach,
            tooltip: 'Import dokumen (PDF) ke SQLite Vector Store',
            icon: const Icon(
              Icons.attach_file_rounded,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textAlignVertical: TextAlignVertical.center,
              textInputAction: TextInputAction.send,
              onSubmitted: isStreaming ? null : (_) => onSend(),
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: isRecording
                    ? 'Merekam… ketuk lagi untuk berhenti'
                    : 'Ask TacitPulse AI…',
                hintStyle:
                    const TextStyle(color: AppColors.textMuted, fontSize: 14),
                filled: false,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
                suffixIcon: ChatMicButton(
                  isRecording: isRecording,
                  enabled: !isStreaming,
                  onStart: onVoiceStart,
                  onStop: onVoiceStop,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: isStreaming ? onStop : onSend,
            tooltip: isStreaming ? 'Hentikan generasi' : 'Kirim',
            icon: Icon(
              isStreaming ? Icons.stop_rounded : Icons.send_rounded,
              color: isStreaming
                  ? AppColors.danger
                  : AppColors.industrialAmber,
              size: isStreaming ? 24 : 20,
            ),
            style: isStreaming
                ? IconButton.styleFrom(
                    backgroundColor:
                        AppColors.danger.withValues(alpha: 0.16),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}