// peer_discovery_cubit.dart — state management untuk discovery peer LAN.

import 'dart:async';

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

class PeerDiscoveryCubit extends Cubit<PeerDiscoveryState> {
  PeerDiscoveryCubit(this._service) : super(const PeerDiscoveryInitial());

  final PeerDiscoveryService _service;
  StreamSubscription<List<DiscoveredPeer>>? _sub;

  /// Mulai broadcasting node ini + scanning peer lain.
  Future<void> start({
    required String deviceName,
    required int port,
    Map<String, String>? txtRecords,
  }) async {
    try {
      emit(const PeerDiscoveryScanning());
      await _service.startBroadcasting(
        deviceName: deviceName,
        port: port,
        txtRecords: txtRecords,
      );
      await _service.startDiscovery();
      _sub?.cancel();
      _sub = _service.discoveredPeersStream.listen((peers) {
        if (peers.isEmpty) {
          emit(const PeerDiscoveryScanning());
        } else {
          emit(PeerDiscoveryActivePeers(peers));
        }
      });
    } catch (e) {
      emit(PeerDiscoveryError('$e'));
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
      await _service.startDiscovery();
      _sub?.cancel();
      _sub = _service.discoveredPeersStream.listen((peers) {
        peers.isEmpty
            ? emit(const PeerDiscoveryScanning())
            : emit(PeerDiscoveryActivePeers(peers));
      });
    } catch (e) {
      emit(PeerDiscoveryError('$e'));
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
    await _sub?.cancel();
    await _service.dispose();
    return super.close();
  }
}
