import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/models/message_model.dart';

void main() {
  final remote = <String, dynamic>{
    'id': 'remote-1',
    'patientId': 'p1',
    'senderId': 'doctor1',
    'content': 'hello',
    'createdAt': '2026-10-20T00:00:00Z',
  };
  test('server messages are synchronized and are not queued for resending', () {
    expect(ChatMessage.fromMap(remote).synced, isTrue);
  });
  test('pending local messages remain pending through serialization', () {
    final pending = ChatMessage.fromMap({...remote, 'synced': 0});
    expect(pending.synced, isFalse);
    expect(ChatMessage.fromMap(pending.toMap()).synced, isFalse);
  });
}
