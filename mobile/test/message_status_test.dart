import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatMessage msg({
    bool synced = true,
    DateTime? delivered,
    DateTime? read,
  }) => ChatMessage(
    id: 'm1',
    patientId: 'p',
    senderId: 'p',
    senderName: 'P',
    senderRole: UserRole.patient,
    channelType: 'doctor_patient',
    content: 'hi',
    createdAt: DateTime.utc(2026),
    synced: synced,
    deliveredAt: delivered,
    readAt: read,
  );

  test('status follows the WhatsApp ladder', () {
    final t = DateTime.utc(2026);
    expect(msg(synced: false).statusFor(), MessageStatus.pending);
    expect(msg(synced: false).statusFor(failed: true), MessageStatus.failed);
    expect(msg().statusFor(), MessageStatus.sent);
    expect(msg(delivered: t).statusFor(), MessageStatus.delivered);
    expect(msg(delivered: t, read: t).statusFor(), MessageStatus.read);
    // A message the server accepted can never show as failed.
    expect(msg().statusFor(failed: true), MessageStatus.sent);
  });

  test('server receipts are parsed, including the group read count', () {
    final m = ChatMessage.fromMap({
      'id': 'x',
      'patientId': 'p',
      'senderId': 's',
      'senderRole': 'patient',
      'channelType': 'care_team_triage',
      'content': 'c',
      'createdAt': '2026-11-27T10:00:00Z',
      'deliveredAt': '2026-11-27T10:00:05Z',
      'readAt': null,
      'readCount': 2,
    });
    expect(m.statusFor(), MessageStatus.delivered);
    expect(m.readCount, 2);
  });
}
