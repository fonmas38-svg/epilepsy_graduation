/// Phases the virtual sensor goes through. This is the GROUND TRUTH kept on
/// the phone for measuring model accuracy; it is never sent to a model.
enum SimPhase { stable, preIctal, onset, ictal, offset, recovery }

extension SimPhaseX on SimPhase {
  /// The signal truly contains seizure activity.
  bool get isSeizure =>
      this == SimPhase.onset ||
      this == SimPhase.ictal ||
      this == SimPhase.offset;

  String label(bool ar) => switch (this) {
    SimPhase.stable => ar ? 'مستقر' : 'Stable',
    SimPhase.preIctal => ar ? 'ما قبل النوبة' : 'Pre-seizure',
    SimPhase.onset => ar ? 'بداية النوبة' : 'Seizure onset',
    SimPhase.ictal => ar ? 'النوبة النشطة' : 'Active seizure',
    SimPhase.offset => ar ? 'نهاية النوبة' : 'Seizure ending',
    SimPhase.recovery => ar ? 'التعافي' : 'Recovery',
  };
}

/// Different seizures, each with its own EEG, heart-rate and motion pattern.
enum SimSeizureType {
  tonicClonic,
  focal,
  absence,
  nocturnal,
  gradual,

  /// Not a seizure: movement / electrode artefacts. Tests false alarms; its
  /// truth stays non-seizure for every phase.
  artifact,
}

extension SimSeizureTypeX on SimSeizureType {
  bool get isEpileptic => this != SimSeizureType.artifact;

  String label(bool ar) => switch (this) {
    SimSeizureType.tonicClonic => ar ? 'توترية-رمعية (كبرى)' : 'Tonic-clonic',
    SimSeizureType.focal => ar ? 'بؤرية' : 'Focal',
    SimSeizureType.absence => ar ? 'غياب' : 'Absence',
    SimSeizureType.nocturnal => ar ? 'ليلية أثناء النوم' : 'Nocturnal',
    SimSeizureType.gradual => ar ? 'متدرجة البداية' : 'Gradual onset',
    SimSeizureType.artifact =>
      ar
          ? 'تشويش غير صرعي (اختبار إنذار كاذب)'
          : 'Non-epileptic artefact (false-alarm test)',
  };
}
