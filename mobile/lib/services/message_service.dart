import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../core/enums.dart';
import '../core/errors/failure.dart';
import '../models/message_model.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'local_database.dart';

class MessageService extends ChangeNotifier {
  MessageService({required this.db, required this.api, required this.auth});
  final LocalDatabase db;
  final ApiClient api;
  final AuthService auth;
  final _uuid = const Uuid();
  List<ChatMessage> doctorMessages = [];
  List<ChatMessage> familyMessages = [];
  Map<String, dynamic>? lastSharedLocation;
  bool loading = false;
  Failure? failure;
  bool _flushing = false;
  String? _patientId;
  int _session = 0;
  int _loadRevision = 0;
  String? get patientId => _patientId;

  bool canAccess(String patientId, {String? channel}) {
    final user = auth.currentUser;
    if (user == null || user.role == UserRole.admin) return false;
    if (channel != null &&
        !['doctor_patient', 'family_patient'].contains(channel)) {
      return false;
    }
    if (user.role == UserRole.caregiver && channel == 'doctor_patient') {
      return false;
    }
    return user.role == UserRole.patient
        ? user.uid == patientId
        : auth.accessiblePatients().any((p) => p.patientId == patientId);
  }

  bool _current(
    AppUser? user,
    String origin,
    int generation,
    String pid, [
    String? channel,
  ]) =>
      generation == _session &&
      identical(auth.currentUser, user) &&
      api.baseUrl == origin &&
      canAccess(pid, channel: channel);

  void clearSession() {
    _session++;
    _loadRevision++;
    _patientId = null;
    doctorMessages = [];
    familyMessages = [];
    lastSharedLocation = null;
    failure = null;
    loading = false;
    notifyListeners();
  }

  Future<void> loadFor(String patientId, {String? channel}) async {
    if (!canAccess(patientId, channel: channel)) {
      clearSession();
      return;
    }
    final user = auth.currentUser;
    final origin = api.baseUrl;
    final generation = _session;
    final revision = ++_loadRevision;
    bool valid() =>
        revision == _loadRevision &&
        _patientId == patientId &&
        _current(user, origin, generation, patientId, channel);
    if (_patientId != patientId) {
      doctorMessages = [];
      familyMessages = [];
      lastSharedLocation = null;
    }
    _patientId = patientId;
    loading = true;
    failure = null;
    notifyListeners();
    try {
      final doctor = user!.role == UserRole.caregiver
          ? <ChatMessage>[]
          : await db.messagesForChannel(patientId, 'doctor_patient');
      if (!valid()) return;
      final family = await db.messagesForChannel(patientId, 'family_patient');
      if (!valid()) return;
      doctorMessages = doctor;
      familyMessages = family;
      notifyListeners();
      if (api.tokens.hasSession) {
        if (user.role != UserRole.caregiver &&
            (channel == null || channel == 'doctor_patient')) {
          await _pull(patientId, 'doctor_patient', valid);
        }
        if (!valid()) return;
        if (channel == null || channel == 'family_patient') {
          await _pull(patientId, 'family_patient', valid);
        }
        if (valid()) await fetchLatestLocation(patientId);
      }
    } catch (error) {
      if (valid()) failure = Failure.from(error);
    } finally {
      if (valid()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _pull(String pid, String channel, bool Function() valid) async {
    if (!valid()) return;
    final res = await api.sendJson(
      method: 'GET',
      path:
          '/patients/${Uri.encodeComponent(pid)}/messages?channel_type=$channel&latest=true',
    );
    if (!valid()) return;
    for (final raw in res['messages'] as List? ?? []) {
      if (!valid()) return;
      if (raw is! Map) continue;
      final msg = ChatMessage.fromMap(Map<String, dynamic>.from(raw));
      if (msg.patientId != pid || msg.channelType != channel || msg.id.isEmpty) {
        throw StateError('Message identity mismatch');
      }
      await db.insertMessage(msg);
    }
    if (!valid()) return;
    final rows = await db.messagesForChannel(pid, channel);
    if (!valid()) return;
    if (channel == 'doctor_patient') {
      doctorMessages = rows;
    } else {
      familyMessages = rows;
    }
    notifyListeners();
  }

  Future<ChatMessage> sendMessage({
    required String patientId,
    required String channelType,
    required String content,
  }) async {
    final user = auth.currentUser;
    final origin = api.baseUrl;
    final generation = _session;
    if (user == null ||
        !canAccess(patientId, channel: channelType) ||
        content.trim().isEmpty ||
        content.trim().length > 5000) {
      throw ArgumentError(
        'Authorized patient/channel and a message of 1–5000 characters are required',
      );
    }
    bool valid() => _current(user, origin, generation, patientId, channelType);
    final local = ChatMessage(
      id: _uuid.v4(),
      patientId: patientId,
      senderId: user.uid,
      senderName: user.name,
      senderRole: user.role,
      channelType: channelType,
      content: content.trim(),
      createdAt: DateTime.now(),
      synced: false,
    );
    await db.insertMessage(local);
    if (!valid()) return local;
    if (_patientId == patientId) {
      (channelType == 'doctor_patient' ? doctorMessages : familyMessages).add(
        local,
      );
      failure = null;
      notifyListeners();
    }
    if (api.tokens.hasSession && valid()) {
      try {
        final server = await _post(local);
        if (!valid()) return local;
        await db.replacePendingMessage(local.id, server);
        if (valid() && _patientId == patientId) {
          _replaceMessage(local.id, server);
          notifyListeners();
        }
        return server;
      } catch (error) {
        if (valid() && _patientId == patientId) {
          failure = Failure.from(error);
          notifyListeners();
        }
      }
    }
    return local;
  }

  Future<ChatMessage> _post(ChatMessage local) async {
    final res = await api.sendJson(
      method: 'POST',
      path: '/patients/${Uri.encodeComponent(local.patientId)}/messages',
      body: {
        'channel_type': local.channelType,
        'client_message_id': local.id,
        'content': local.content,
      },
    );
    if (res['message'] is! Map) {
      throw StateError('Message acceptance not confirmed');
    }
    final server = ChatMessage.fromMap(
      Map<String, dynamic>.from(res['message'] as Map),
    );
    if (server.patientId != local.patientId ||
        server.channelType != local.channelType ||
        server.senderId != local.senderId ||
        server.id.isEmpty) {
      throw StateError('Message acknowledgment identity mismatch');
    }
    return server;
  }

  void _replaceMessage(String oldId, ChatMessage message) {
    final list = message.isDoctorPatient ? doctorMessages : familyMessages;
    final index = list.indexWhere((row) => row.id == oldId);
    if (index >= 0) list[index] = message;
  }

  Future<int> flushPendingMessages() async {
    final user = auth.currentUser;
    final origin = api.baseUrl;
    final generation = _session;
    if (!api.tokens.hasSession || user == null || _flushing) return 0;
    _flushing = true;
    var count = 0;
    try {
      final pending = await db.unsyncedMessages(user.uid);
      for (final row in pending) {
        bool valid() =>
            _current(user, origin, generation, row.patientId, row.channelType);
        if (!valid()) break;
        if (row.senderId != user.uid) continue;
        final server = await _post(row);
        if (!valid()) break;
        await db.replacePendingMessage(row.id, server);
        if (valid() && _patientId == row.patientId) {
          _replaceMessage(row.id, server);
        }
        count++;
      }
    } catch (_) {
      /* Keep pending rows with their original sender and ID. */
    } finally {
      _flushing = false;
    }
    if (count > 0 &&
        identical(auth.currentUser, user) &&
        generation == _session) {
      notifyListeners();
    }
    return count;
  }

  Future<Map<String, dynamic>?> shareLocation({
    required String patientId,
    required double latitude,
    required double longitude,
    double? accuracy,
    String? note,
  }) async {
    final user = auth.currentUser;
    final origin = api.baseUrl;
    final generation = _session;
    if (user?.role != UserRole.patient ||
        user?.uid != patientId ||
        !api.tokens.hasSession ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        (accuracy != null && (!accuracy.isFinite || accuracy < 0))) {
      throw StateError(
        'A signed-in patient, connection and valid coordinates are required',
      );
    }
    bool valid() => _current(user, origin, generation, patientId);
    final res = await api.sendJson(
      method: 'POST',
      path: '/patients/${Uri.encodeComponent(patientId)}/location',
      body: {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'note': note,
      },
    );
    if (!valid()) return null;
    final loc = res['location'] is Map
        ? Map<String, dynamic>.from(res['location'] as Map)
        : null;
    if (loc == null) throw StateError('Location sharing was not confirmed');
    if (_patientId == patientId) {
      lastSharedLocation = loc;
      notifyListeners();
    }
    return loc;
  }

  Future<Map<String, dynamic>?> fetchLatestLocation(String patientId) async {
    final user = auth.currentUser;
    final origin = api.baseUrl;
    final generation = _session;
    if (!canAccess(patientId)) return null;
    if (!api.tokens.hasSession) {
      return _patientId == patientId ? lastSharedLocation : null;
    }
    try {
      final res = await api.sendJson(
        method: 'GET',
        path: '/patients/${Uri.encodeComponent(patientId)}/location',
      );
      if (!_current(user, origin, generation, patientId)) return null;
      final loc = res['location'] is Map
          ? Map<String, dynamic>.from(res['location'] as Map)
          : null;
      if (_patientId == patientId) {
        lastSharedLocation = loc;
        notifyListeners();
      }
      return loc;
    } catch (_) {
      return _patientId == patientId &&
              _current(user, origin, generation, patientId)
          ? lastSharedLocation
          : null;
    }
  }
}
