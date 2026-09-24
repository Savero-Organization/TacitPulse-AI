import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Terminal CLI daemon node: output log + input command dengan prompt.
class DaemonCliTerminal extends StatefulWidget {
  const DaemonCliTerminal({super.key, this.modelHosted = true});

  /// True bila node memegang file model GGUF lokal yang valid. Bila `false`,
  /// daemon TIDAK menyiarkan "chunks seeded" untuk model — Bitswap provider
  /// hanya idle sampai ada file model yang benar-benar di-host.
  final bool modelHosted;

  @override
  State<DaemonCliTerminal> createState() => _DaemonCliTerminalState();
}

class _DaemonCliTerminalState extends State<DaemonCliTerminal> {
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  late final List<String> _logs = _buildInitialLogs(widget.modelHosted);

  static List<String> _buildInitialLogs(bool modelHosted) => [
        'tacit-node v0.4.2 daemon initialized in FULL NODE mode',
        'Swarm listening on /ip4/0.0.0.0/tcp/4001/p2p/12D3KooW...',
        'Kademlia DHT Server active · 28 k-buckets populated',
        'AutoNAT service: Public IP verified via Relay-02',
        modelHosted
            ? 'Bitswap provider engine ready · 128 chunks seeded'
            : 'Bitswap provider engine idle · no local GGUF to seed',
        'Type "help" for available node commands.',
      ];

  @override
  void dispose() {
    _inputCtrl.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _runCommand(String cmd) {
    if (cmd.trim().isEmpty) return;
    setState(() {
      _logs.add('\$ $cmd');
      final lower = cmd.trim().toLowerCase();
      if (lower == 'help') {
        _logs.add('Available commands:');
        _logs.add('  swarm peers     - List connected P2P peers & latency');
        _logs.add('  status          - Show daemon health and uptime');
        _logs.add('  config          - Print node settings');
        _logs.add('  clear           - Clear terminal screen');
      } else if (lower.contains('swarm peers')) {
        _logs.add('12D3KooW... /ip4/192.168.1.104/tcp/4001 (latency 12ms)');
        _logs.add('12D3KooX... /ip4/192.168.1.112/tcp/4001 (latency 38ms)');
      } else if (lower.contains('status')) {
        _logs.add('Daemon status: ONLINE | DHT: active | Peers: 5');
      } else if (lower.contains('config')) {
        _logs.add('Swarm.ConnMgr.HighWater: 100 | StorageMax: 128GB');
      } else if (lower == 'clear') {
        _logs.clear();
      } else {
        _logs.add('Executing: $cmd [OK]');
      }
    });
    _inputCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: Container(
        color: const Color(0xFF0B0F17),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logs.length,
                itemBuilder: (ctx, i) {
                  final isCmd = _logs[i].startsWith('\$');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      _logs[i],
                      style: TextStyle(
                        color: isCmd ? AppColors.cyanAccent : AppColors.success,
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        height: 1.3,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text(
                  'tacit-node> ',
                  style: TextStyle(
                    color: AppColors.industrialAmber,
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: TextField(
                    focusNode: _focusNode,
                    controller: _inputCtrl,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                    cursorColor: AppColors.cyanAccent,
                    cursorWidth: 7,
                    cursorHeight: 14,
                    decoration: const InputDecoration(
                      hintText: 'type command (help, swarm peers, config...)',
                      hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11.5, fontFamily: 'monospace'),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onSubmitted: (cmd) {
                      _runCommand(cmd);
                      _focusNode.requestFocus();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}