// transfer_progress_card.dart — kartu status transfer (progress/speed/ETA).

import 'package:flutter/material.dart';

import '../models/transfer_status.dart';

/// Kartu yang memonitor satu transfer [TransferStatusController].
class TransferProgressCard extends StatelessWidget {
  const TransferProgressCard({
    super.key,
    required this.controller,
    this.onCancel,
    this.onRetry,
  });

  final TransferStatusController controller;
  final void Function()? onCancel;
  final void Function()? onRetry;

  void _togglePause() {
    final s = controller.value;
    if (s.state == TransferState.transferring) {
      controller.value = s.copyWith(state: TransferState.paused);
    } else if (s.state == TransferState.paused) {
      controller.value = s.copyWith(state: TransferState.transferring);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TransferStatus>(
      valueListenable: controller,
      builder: (context, status, _) {
        final theme = Theme.of(context).colorScheme;
        return Card(
          key: const Key('transfer_card'),
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.insert_drive_file, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(status.fileName)),
                    Text(formatPercent(status.progress)),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const Key('transfer_progress_bar'),
                  value: status.progress,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '${status.receivedMB.toStringAsFixed(1)} MB / '
                      '${status.totalMB.toStringAsFixed(1)} MB',
                    ),
                    const Spacer(),
                    Text(formatSpeed(status.speedBytesPerSec)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(_stateLabel(status.state),
                        style: TextStyle(color: theme.primary)),
                    const Spacer(),
                    if (!status.isFailed)
                      Text('ETA ${formatEta(status.remaining)}'),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (status.state == TransferState.transferring ||
                        status.state == TransferState.paused)
                      OutlinedButton.icon(
                        key: const Key('pause_toggle'),
                        onPressed: _togglePause,
                        icon: Icon(status.isPaused
                            ? Icons.play_arrow
                            : Icons.pause),
                        label: Text(status.isPaused ? 'Resume' : 'Pause'),
                      ),
                    if (!status.isCompleted)
                      OutlinedButton(
                        key: const Key('cancel_button'),
                        onPressed: onCancel,
                        child: const Text('Cancel'),
                      ),
                    if (status.isFailed)
                      FilledButton.icon(
                        key: const Key('retry_button'),
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _stateLabel(TransferState s) {
    switch (s) {
      case TransferState.connecting:
        return 'Connecting…';
      case TransferState.transferring:
        return 'Transferring';
      case TransferState.paused:
        return 'Paused';
      case TransferState.completed:
        return 'Completed';
      case TransferState.failed:
        return 'Failed';
    }
  }
}