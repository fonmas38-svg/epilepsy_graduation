import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/enums.dart';
import '../core/errors/failure.dart';
import '../models/message_model.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'local_database.dart';

class MessageService extends ChangeNotifier {
  MessageService({
    required this.db,
    required this.api,
    required this.auth,
  });

  final LocalDatabase db;
  final ApiClient api;
  final AuthService auth;

  final _uuid = const Uuid();

  List<ChatMessage> doctorMessages = [];
  List<ChatMessage> familyMessages = [];
  Map<String, dynamic>? lastSharedLocation;
  bool loading = false;
  Failure? failure;

  /// Load messages for [patientId] from local SQLite first, then refresh from cloud if online.
  Future<void> loadFor(String patientId, {String? channel}) async {
    loading = true;
    failure = null;
    notifyListeners();

    final role = auth.currentUser?.role ?? UserRole.patient;

    try {
      // 1. Load from local database immediately
      if (role != UserRole.caregiver) {
        doctorMessages = await db.messagesForChannel(patientId, 'doctor_patient');
      } else {
        doctorMessages = []; // Caregiver never sees private doctor consultations
      }
      familyMessages = await db.messagesForChannel(patientId, 'family_patient');
      notifyListeners();

      // 2. Fetch from cloud API if user has active session
      if (api.tokens.hasSession) {
        if (role != UserRole.caregiver && (channel == null || channel == 'doctor_patient')) {
          await _syncChannelFromCloud(patientId, 'doctor_patient');
        }
        if (channel == null || channel == 'family_patient') {
          await _syncChannelFromCloud(patientId, 'family_patient');
        }

        // Also fetch latest location
        await fetchLatestLocation(patientId);
      }
    } catch (e) {
      failure = Failure.from(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _syncChannelFromCloud(String patientId, String channelType) async {
    try {
      final res = await api.sendJson(
        method: 'GET',
        path: '/patients/$patientId/messages?channel_type=$channelType',
      );
      final rawList = res['messages'] as List? ?? [];
      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          final msg = ChatMessage.fromMap(item);
          await db.insertMessage(msg);
        }
      }
      // Re-read local for consistency
      if (channelType == 'doctor_patient') {
        doctorMessages = await db.messagesForChannel(patientId, 'doctor_patient');
      } else {
        familyMessages = await db.messagesForChannel(patientId, 'family_patient');
      }
    } catch (_) {
      // Offline fallback: keep locally cached rows
    }
  }

  /// Send a message with instant local optimistic UI + cloud sync
  Future<ChatMessage> sendMessage({
    required String patientId,
    required String channelType,
    required String content,
  }) async {
    final user = auth.currentUser;
    final role = user?.role ?? UserRole.patient;

    final localMsg = ChatMessage(
      id: _uuid.v4(),
      patientId: patientId,
      senderId: user?.uid ?? 'unknown',
      senderName: user?.name ?? 'مستخدم',
      senderRole: role,
      channelType: channelType,
      content: content.trim(),
      createdAt: DateTime.now(),
      synced: false,
    );

    // Save locally
    await db.insertMessage(localMsg);
    if (channelType == 'doctor_patient') {
      doctorMessages.add(localMsg);
    } else {
      familyMessages.add(localMsg);
    }
    notifyListeners();

    // Cloud sync
    if (api.tokens.hasSession) {
      try {
        final res = await api.sendJson(
          method: 'POST',
          path: '/patients/$patientId/messages',
          body: {
            'channel_type': channelType,
            'content': content.trim(),
          },
        );
        final serverMap = res['message'] as Map<String, dynamic>?;
        if (serverMap != null) {
          final serverMsg = ChatMessage.fromMap(serverMap);
          await db.insertMessage(serverMsg);
          await db.markMessageSynced(localMsg.id);
          _replaceMessage(localMsg.id, serverMsg);
          notifyListeners();
          return serverMsg;
        }
      } catch (_) {
        // Stays unsynced in local SQLite for later sync
      }
    }
    return localMsg;
  }

  void _replaceMessage(String oldId, ChatMessage newMsg) {
    final list = newMsg.channelType == 'doctor_patient' ? doctorMessages : familyMessages;
    final idx = list.indexWhere((m) => m.id == oldId);
    if (idx != -1) {
      list[idx] = newMsg;
    }
  }

  /// Drain pending offline messages from SQLite to the backend API when connected.
  Future<int> flushPendingMessages() async {
    if (!api.tokens.hasSession) return 0;
    try {
      final pending = await db.unsyncedMessages();
      if (pending.isEmpty) return 0;
      int flushed = 0;
      for (final msg in pending) {
        try {
          final res = await api.sendJson(
            method: 'POST',
            path: '/patients/${msg.patientId}/messages',
            body: {
              'channel_type': msg.channelType,
              'content': msg.content,
            },
          );
          final serverMap = res['message'] as Map<String, dynamic>?;
          if (serverMap != null) {
            final serverMsg = ChatMessage.fromMap(serverMap);
            await db.insertMessage(serverMsg);
            await db.markMessageSynced(msg.id);
            _replaceMessage(msg.id, serverMsg);
            flushed++;
          }
        } catch (_) {
          break; // Network still unavailable, retry on next cycle
        }
      }
      if (flushed > 0) {
        notifyListeners();
      }
      return flushed;
    } catch (_) {
      return 0;
    }
  }

  /// Share current patient location with family
  Future<Map<String, dynamic>?> shareLocation({
    required String patientId,
    required double latitude,
    required double longitude,
    double? accuracy,
    String? note,
  }) async {
    final locData = {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'note': note,
      'updatedAt': DateTime.now().toIso8601String(),
      'mapsUrl': 'https://maps.google.com/?q=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}',
    };
    lastSharedLocation = locData;
    notifyListeners();

    if (api.tokens.hasSession) {
      try {
        final res = await api.sendJson(
          method: 'POST',
          path: '/patients/$patientId/location',
          body: {
            'latitude': latitude,
            'longitude': longitude,
            'accuracy': accuracy,
            'note': note,
          },
        );
        final loc = res['location'] as Map<String, dynamic>?;
        if (loc != null) {
          lastSharedLocation = loc;
          // Reload family messages because a location broadcast was posted!
          await _syncChannelFromCloud(patientId, 'family_patient');
          notifyListeners();
          return loc;
        }
      } catch (_) {
        // Offline
      }
    }
    return locData;
  }

  Future<Map<String, dynamic>?> fetchLatestLocation(String patientId) async {
    if (!api.tokens.hasSession) return lastSharedLocation;
    try {
      final res = await api.sendJson(
        method: 'GET',
        path: '/patients/$patientId/location',
      );
      final loc = res['location'] as Map<String, dynamic>?;
      if (loc != null) {
        lastSharedLocation = loc;
        notifyListeners();
        return loc;
      }
    } catch (_) {}
    return lastSharedLocation;
  }
}
