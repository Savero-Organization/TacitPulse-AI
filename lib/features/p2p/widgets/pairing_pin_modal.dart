// pairing_pin_modal.dart — modal konfirmasi PIN 4 digit.


import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// Mode: [PairingPinMode.display] menampilkan PIN yang harus diketik
/// peer lain; [PairingPinMode.entry] adalah input 4 digit.
enum PairingPinMode { generate, entry }

/// Bottom-sheet/dialog aman untuk verifikasi PIN koneksi.
class PairingPinModal extends StatefulWidget {
  const PairingPinModal({
    super.key,
    required this.peerName,
    required this.expectedPin,
    this.mode = PairingPinMode.entry,
    this.timeoutSeconds = 30,
    this.onApprove,
    this.onReject,
    this.onTimeout,
  }) : assert(expectedPin.length == 4 || mode == PairingPinMode.generate,
            'expectedPin harus 4 digit');

  /// Nama peer/device yang meminta koneksi.
  final String peerName;
  final String expectedPin;
  final PairingPinMode mode;

  /// Batas waktu input PIN (detik); saat habis → [onTimeout].
  final int timeoutSeconds;

  /// Dipanggil saat PIN valid disetujui.
  final void Function()? onApprove;

  /// Dipanggil saat pengguna menolak / menutup modal.
  final void Function()? onReject;

  /// Dipanggil saat hitung mundur habis.
  final void Function()? onTimeout;

  @override
  State<PairingPinModal> createState() => PairingPinModalState();
}

class PairingPinModalState extends State<PairingPinModal>
    with SingleTickerProviderStateMixin {
  final _controllers = List.generate(4, (_) => TextEditingController());
  final _focusNodes = List.generate(4, (_) => FocusNode());
  String? _error;
  late int _remaining;
  Ticker? _ticker;
  bool _timedOut = false;

  /// Tampilan sisa detik — dapat dibaca UI & test.
  String get remainingLabel => '${_remaining}s';

  /// Semua 4 kotak sudah terisi.
  bool get isComplete => _controllers.every((c) => c.text.isNotEmpty);

  String get _entered => _controllers.map((c) => c.text).join();

  @override
  void initState() {
    super.initState();
    _remaining = widget.timeoutSeconds;
    if (widget.mode == PairingPinMode.entry) {
      // Pakai Ticker (bukan Timer) agar hitung mundur ikut clock framework &
      // dapat didorong langsung oleh widget test via `tester.pump`.
      _ticker = createTicker((d) {
        if (!mounted || _timedOut) return;
        final next = widget.timeoutSeconds - d.inSeconds;
        if (next != _remaining) {
          setState(() {
            _remaining = next.clamp(0, widget.timeoutSeconds);
            if (_remaining == 0) {
              _timedOut = true;
              _error = 'Waktu habis';
              widget.onTimeout?.call();
              _ticker?.stop();
            }
          });
        }
      })
        ..start();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _onChanged(int index, String value) {
    // Hanya 1 digit; digit lama diganti oleh digit baru.
    if (value.length > 1) {
      _controllers[index].text = value.substring(value.length - 1);
      _controllers[index].selection = TextSelection.collapsed(offset: 1);
    } else if (value.isNotEmpty && !RegExp(r'^\d$').hasMatch(value)) {
      _controllers[index].clear();
      return;
    }
    setState(() => _error = null);
    if (value.isNotEmpty && index < 3) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isEmpty && index > 0) {
      // Backspace mengosongkan kotak ini: pindahkan fokus ke kotak
      // sebelumnya agar penghapusan berlanjut ke digit sebelumnya.
      _focusNodes[index - 1].requestFocus();
    }
  }

  void _approve() {
    if (widget.mode == PairingPinMode.generate) {
      widget.onApprove?.call();
      return;
    }
    if (!isComplete) {
      setState(() => _error = 'Masukkan 4 digit PIN');
      return;
    }
    if (_entered != widget.expectedPin) {
      setState(() => _error = 'PIN salah, coba lagi');
      return;
    }
    widget.onApprove?.call();
  }

  void _reject() {
    widget.onReject?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.mode == PairingPinMode.generate
          ? 'Share PIN ke ${widget.peerName}'
          : 'Hubungkan ke ${widget.peerName}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.mode == PairingPinMode.generate)
              Text(widget.expectedPin,
                  key: const Key('generated_pin_display'),
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(letterSpacing: 8))
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  return SizedBox(
                    width: 52,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TextField(
                        key: Key('pin_digit_$i'),
                        controller: _controllers[i],
                        focusNode: _focusNodes[i],
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.number,
                        maxLength: 1,
                        onChanged: (v) => _onChanged(i, v),
                        decoration: const InputDecoration(
                          counterText: '',
                          enabledBorder: OutlineInputBorder(),
                          focusedBorder: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 8),
              Text('PIN berakhir dalam $remainingLabel',
                  key: const Key('pin_countdown')),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    key: const Key('pin_error'),
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pin_reject'),
          onPressed: _reject,
          child: const Text('Reject'),
        ),
        FilledButton(
          key: const Key('pin_approve'),
          onPressed: _approve,
          child: Text(widget.mode == PairingPinMode.generate ? 'Selesai' : 'Approve'),
        ),
      ],
    );
  }
}