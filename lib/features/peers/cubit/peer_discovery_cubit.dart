// peer_discovery_cubit.dart — state management untuk discovery peer LAN.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/peer_discovery_service.dart';

abstract class PeerDiscoveryState {
  const PeerDiscoveryState();
}

class PeerDiscoveryInitial extends PeerDiscoveryState {
  const PeerDiscoveryInitial();
}

class PeerDiscoveryScanning extends PeerDiscoveryState {
  const PeerDiscoveryScanning();
}

class PeerDiscoveryActivePeers extends PeerDiscoveryState {
  const PeerDiscoveryActivePeers(this.peers);
  final List<DiscoveredPeer> peers;
}

class PeerDiscoveryError extends PeerDiscoveryState {
  const PeerDiscoveryError(this.message);
  final String message;
}

class PeerDiscoveryCubit extends Cubit<PeerDiscoveryState>
    with WidgetsBindingObserver {
  PeerDiscoveryCubit(this._service) : super(const PeerDiscoveryInitial()) {
    WidgetsBinding.instance.addObserver(this);
  }

  final PeerDiscoveryService _service;
  StreamSubscription<List<DiscoveredPeer>>? _sub;
  String? _lastDeviceName;
  int? _lastPort;
  Map<String, String>? _lastTxtRecords;

  /// Mulai broadcasting node ini + scanning peer lain.
  Future<void> start({
    required String deviceName,
    required int port,
    Map<String, String>? txtRecords,
  }) async {
    if (isClosed) return;
    _lastDeviceName = deviceName;
    _lastPort = port;
    _lastTxtRecords = txtRecords;
    try {
      emit(const PeerDiscoveryScanning());
      await _service.startBroadcasting(
        deviceName: deviceName,
        port: port,
        txtRecords: txtRecords,
      );
      if (isClosed) return;
      await _service.startDiscovery();
      if (isClosed) return;
      _sub?.cancel();
      _sub = _service.discoveredPeersStream.listen((peers) {
        if (isClosed) return;
        if (peers.isEmpty) {
          emit(const PeerDiscoveryScanning());
        } else {
          emit(PeerDiscoveryActivePeers(peers));
        }
      });
    } catch (e) {
      if (!isClosed) emit(PeerDiscoveryError('$e'));
    }
  }

  /// Restart scanning (mis. pull-to-refresh): reset state lalu subscribe ulang.
  Future<void> refresh({
    required String deviceName,
    required int port,
    Map<String, String>? txtRecords,
  }) async {
    await _sub?.cancel();
    await _service.stopDiscovery();
    await start(
      deviceName: deviceName,
      port: port,
      txtRecords: txtRecords,
    );
  }

  Future<void> startScanningOnly() async {
    try {
      emit(const PeerDiscoveryScanning());
      if (isClosed) return;
      await _service.startDiscovery();
      if (isClosed) return;
      _sub?.cancel();
      _sub = _service.discoveredPeersStream.listen((peers) {
        if (isClosed) return;
        peers.isEmpty
            ? emit(const PeerDiscoveryScanning())
            : emit(PeerDiscoveryActivePeers(peers));
      });
    } catch (e) {
      if (!isClosed) emit(PeerDiscoveryError('$e'));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Hentikan broadcast & discovery saat app di background supaya
        // tidak menyedot baterai / menahan multicast lock.
        _service.stopDiscovery();
        _service.stopBroadcasting();
        _sub?.cancel();
        _sub = null;
        break;
      case AppLifecycleState.resumed:
        // Restart otomatis dengan konfigurasi yang pernah dipakai.
        final name = _lastDeviceName;
        final port = _lastPort;
        if (name != null && port != null) {
          start(
            deviceName: name,
            port: port,
            txtRecords: _lastTxtRecords,
          );
        }
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _service.stopDiscovery();
    await _service.stopBroadcasting();
    emit(const PeerDiscoveryInitial());
  }

  @override
  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    await _sub?.cancel();
    await _service.dispose();
    return super.close();
  }
}
