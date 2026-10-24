import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/message_model.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/models/prediction_state.dart';
import 'package:epilepsy_monitor/services/signal_simulator.dart';

void main() {
  test('simulator defaults match the current model input contract', () {
    final reading = SignalSimulator(random: Random(42)).generate(patientId: 'p1');
    expect(reading.eeg.length, 262);
    expect(SignalSimulator.sampleRateHz, 256);
  });

  test('packet boundaries do not change simulated signal frequency', () {
    final whole = SignalSimulator(random: Random(42))
        .generate(patientId: 'p1', samples: 256);
    final split = SignalSimulator(random: Random(42));
    final parts = List.generate(8, (_) => split.generate(patientId: 'p1', samples: 32));
    expect(parts.expand((p) => p.eeg).toList(), whole.eeg);
    expect(parts.expand((p) => p.ecg).toList(), whole.ecg);
    expect(parts.expand((p) => p.motion).toList(), whole.motion);
  });

  test('empty simulator windows are rejected before inference', () {
    expect(() => SignalSimulator().generate(patientId: 'p1', samples: 0), throwsRangeError);
  });

  test('simulator generates expected sample counts', () {
    final sim = SignalSimulator();
    final reading = sim.generate(patientId: 'p1', pattern: RiskLabel.stable, samples: 32);
    expect(reading.eeg.length, 32);
    expect(reading.ecg.length, 32);
    expect(reading.motion.length, 32);
    expect(reading.hr, greaterThan(0));
  });

  test('pattern cycle includes high risk', () {
    final sim = SignalSimulator();
    expect(sim.patternForTick(4), RiskLabel.highRisk);
    expect(sim.patternForTick(0), RiskLabel.stable);
  });

  test('ChatMessage correctly maps to/from json and channel properties', () {
    final now = DateTime.now();
    final msg = ChatMessage(
      id: 'msg-101',
      patientId: 'pat-1',
      senderId: 'doc-1',
      senderName: 'Dr. Test',
      senderRole: UserRole.doctor,
      channelType: 'doctor_patient',
      content: 'Medical directive message',
      createdAt: now,
      synced: true,
    );

    expect(msg.isDoctorPatient, isTrue);
    expect(msg.isFamilyPatient, isFalse);

    final map = msg.toMap();
    expect(map['channelType'], 'doctor_patient');
    expect(map['senderRole'], 'doctor');

    final restored = ChatMessage.fromMap(map);
    expect(restored.id, 'msg-101');
    expect(restored.senderName, 'Dr. Test');
    expect(restored.senderRole, UserRole.doctor);
    expect(restored.content, 'Medical directive message');
    expect(restored.isDoctorPatient, isTrue);
  });

  test('PatientProfile correctly maps phone field', () {
    final profile = PatientProfile(
      patientId: 'pat-10',
      name: 'Test Patient',
      phone: '+966500000000',
    );
    expect(profile.phone, '+966500000000');
    final map = profile.toMap();
    expect(map['phone'], '+966500000000');
    final restored = PatientProfile.fromMap(map);
    expect(restored.phone, '+966500000000');
  });

  test('PredictionState toMap correctly reflects fields', () {
    const ps = PredictionState(
      preictalProb: 0.88,
      leadTimeMin: 12.0,
      horizonMin: 15.0,
      predicted: true,
      source: 'simulator',
      trajectory: [0.1, 0.4, 0.88],
    );
    final map = ps.toMap();
    expect(map['preictal_prob'], 0.88);
    expect(map['lead_time_min'], 12.0);
    expect(map['predicted'], isTrue);
    expect(map['prediction_source'], 'simulator');
  });
}

