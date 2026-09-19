import 'dart:convert';

class WorkerProfile {
  const WorkerProfile({
    required this.fullName,
    required this.employeeId,
    required this.workArea,
    required this.shift,
    required this.nodeName,
    this.isFullNode = true,
  });

  final String fullName;
  final String employeeId;
  final String workArea;
  final String shift;
  final String nodeName;
  final bool isFullNode;

  static const List<String> workAreas = [
    'Line 1 - Packaging',
    'Line 2 - Filling',
    'Line 3 - Mixing',
    'Utility & Boiler',
    'Warehouse',
    'QC Lab',
  ];

  static const List<String> shifts = [
    'Shift 1 (06:00 - 14:00)',
    'Shift 2 (14:00 - 22:00)',
    'Shift 3 (22:00 - 06:00)',
  ];

  static String generateNodeName(String fullName, String workArea) {
    final parts = fullName.split(' ');
    final firstName = parts.isNotEmpty ? parts.first.toUpperCase() : 'TEK';
    final areaCode = workArea.split(' - ').first.replaceAll('Line ', 'LINE').replaceAll(' ', '').toUpperCase();
    return 'TEK-$areaCode-$firstName';
  }

  WorkerProfile copyWith({
    String? fullName,
    String? employeeId,
    String? workArea,
    String? shift,
    String? nodeName,
    bool? isFullNode,
  }) {
    return WorkerProfile(
      fullName: fullName ?? this.fullName,
      employeeId: employeeId ?? this.employeeId,
      workArea: workArea ?? this.workArea,
      shift: shift ?? this.shift,
      nodeName: nodeName ?? this.nodeName,
      isFullNode: isFullNode ?? this.isFullNode,
    );
  }

  String toJson() => jsonEncode({
        'fullName': fullName,
        'employeeId': employeeId,
        'workArea': workArea,
        'shift': shift,
        'nodeName': nodeName,
        'isFullNode': isFullNode,
      });

  factory WorkerProfile.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return WorkerProfile(
      fullName: map['fullName'] as String? ?? '',
      employeeId: map['employeeId'] as String? ?? '',
      workArea: map['workArea'] as String? ?? '',
      shift: map['shift'] as String? ?? '',
      nodeName: map['nodeName'] as String? ?? '',
      isFullNode: map['isFullNode'] as bool? ?? true,
    );
  }
}
