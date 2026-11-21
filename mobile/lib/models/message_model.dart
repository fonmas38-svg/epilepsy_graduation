import '../core/enums.dart';

/// Represents a chat/consultation message in either the private doctor-patient
/// channel or the family care circle channel.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.patientId,
    required this.senderId,
    required this.senderName,
    required this.senderRole,
    required this.channelType,
    required this.content,
    required this.createdAt,
    this.readAt,
    this.synced = true,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String senderId;
  final String senderName;
  final UserRole senderRole;
  final String channelType; // 'doctor_patient' or 'family_patient'
  final String content;
  final DateTime createdAt;
  final DateTime? readAt;
  final bool synced;
  final String serverOrigin;

  bool get isDoctorPatient => channelType == 'doctor_patient';
  bool get isFamilyPatient => channelType == 'family_patient';

  ChatMessage copyWith({
    String? id,
    String? patientId,
    String? senderId,
    String? senderName,
    UserRole? senderRole,
    String? channelType,
    String? content,
    DateTime? createdAt,
    DateTime? readAt,
    bool? synced,
    String? serverOrigin,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        patientId: patientId ?? this.patientId,
        senderId: senderId ?? this.senderId,
        senderName: senderName ?? this.senderName,
        senderRole: senderRole ?? this.senderRole,
        channelType: channelType ?? this.channelType,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
        readAt: readAt ?? this.readAt,
        synced: synced ?? this.synced,
        serverOrigin: serverOrigin ?? this.serverOrigin,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'senderId': senderId,
        'senderName': senderName,
        'senderRole': senderRole.name,
        'channelType': channelType,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'readAt': readAt?.toIso8601String(),
        'synced': synced ? 1 : 0,
        'serverOrigin': serverOrigin,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    UserRole parsedRole;
    final roleRaw = (map['senderRole'] ?? map['sender_role'] ?? '').toString();
    if (roleRaw == 'doctor') {
      parsedRole = UserRole.doctor;
    } else if (roleRaw == 'caregiver') {
      parsedRole = UserRole.caregiver;
    } else {
      parsedRole = UserRole.patient;
    }

    DateTime parsedCreated;
    final createdRaw = map['createdAt'] ?? map['created_at'];
    if (createdRaw is String) {
      parsedCreated = DateTime.tryParse(createdRaw) ?? DateTime.now();
    } else {
      parsedCreated = DateTime.now();
    }

    DateTime? parsedRead;
    final readRaw = map['readAt'] ?? map['read_at'];
    if (readRaw is String && readRaw.isNotEmpty) {
      parsedRead = DateTime.tryParse(readRaw);
    }

    return ChatMessage(
      id: map['id'] as String? ?? '',
      patientId: (map['patientId'] ?? map['patient_id'] ?? '') as String,
      senderId: (map['senderId'] ?? map['sender_id'] ?? '') as String,
      senderName: (map['senderName'] ?? map['sender_name'] ?? 'مستخدم') as String,
      senderRole: parsedRole,
      channelType: (map['channelType'] ?? map['channel_type'] ?? 'family_patient') as String,
      content: (map['content'] ?? '') as String,
      createdAt: parsedCreated,
      readAt: parsedRead,
      synced: !map.containsKey('synced') || map['synced'] == 1 || map['synced'] == true,
      serverOrigin: map['serverOrigin'] as String? ?? '',
    );
  }
}
