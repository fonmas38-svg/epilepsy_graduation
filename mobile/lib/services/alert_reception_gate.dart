/// Foreground deduplication and patient authorization, scoped to an account.
/// This does not suppress OS-rendered background notifications or prove delivery.
class AlertReceptionGate {
  String? _userId;
  Set<String> _patients = {};
  final Map<String, DateTime> _seen = {};

  void configure(String? userId, Iterable<String> patientIds) {
    if (_userId != userId) _seen.clear();
    _userId = userId;
    _patients = userId == null ? {} : patientIds.toSet();
  }

  bool accept(String? patientId, String? alertId, {DateTime? now}) {
    if (_userId == null ||
        patientId == null ||
        alertId == null ||
        alertId.isEmpty ||
        !_patients.contains(patientId)) {
      return false;
    }
    final at = now ?? DateTime.now();
    _seen.removeWhere(
      (_, seenAt) => at.difference(seenAt) > const Duration(days: 1),
    );
    final key = '$patientId:$alertId';
    if (_seen.containsKey(key)) return false;
    _seen[key] = at;
    while (_seen.length > 512) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }
}
