import 'package:flutter/widgets.dart';

/// Central string table — `docs/frontend-plan-ar.md` §2.3.
///
/// **Rule enforced here:** no Arabic (or English) literal belongs in a widget.
/// Screens read every label through `AppLocalizations.of(context)`, so adding a
/// language is one new map and translating a screen never means touching it.
///
/// **Deviation from the plan, on purpose:** the plan specifies `.arb` files with
/// generated bindings. This uses a hand-written delegate with two `const` maps
/// instead, because that needs no `gen-l10n` / `build_runner` step — the app
/// builds from a clean checkout with nothing but `flutter pub get`. The property
/// the plan actually cares about (one place for every string, zero literals in
/// widgets) is identical either way, and migrating to ARB later is a mechanical
/// transform of these two maps.
///
/// Call sites use getters, so a typo in a screen is a **compile error**. A typo
/// in a map key here degrades to showing the key name rather than crashing —
/// deliberate, so a missing translation can never stop the app from starting.
class AppLocalizations {
  const AppLocalizations(this.locale);

  final Locale locale;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// Arabic first (§11.6) — it is the primary language, not a translation.
  static const List<Locale> supportedLocales = [Locale('ar'), Locale('en')];

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations(Locale('ar'));

  bool get isArabic => locale.languageCode == 'ar';

  Map<String, String> get _table => isArabic ? _ar : _en;

  String _s(String key) => _table[key] ?? _ar[key] ?? key;

  /// Substitute `{name}` placeholders. Keeps parameterised strings translatable
  /// without positional-argument bugs when word order differs between languages.
  String _p(String key, Map<String, Object?> args) {
    var out = _s(key);
    for (final e in args.entries) {
      out = out.replaceAll('{${e.key}}', '${e.value}');
    }
    return out;
  }

  // ------------------------------------------------------------------- common
  String get appTitle => _s('appTitle');
  String get appSubtitle => _s('appSubtitle');
  String get ok => _s('ok');
  String get cancel => _s('cancel');
  String get save => _s('save');
  String get delete => _s('delete');
  String get edit => _s('edit');
  String get add => _s('add');
  String get close => _s('close');
  String get retry => _s('retry');
  String get back => _s('back');
  String get yes => _s('yes');
  String get no => _s('no');
  String get loading => _s('loading');
  String get search => _s('search');
  String get all => _s('all');
  String get none => _s('none');
  String get unknown => _s('unknown');
  String get refresh => _s('refresh');
  String get export => _s('export');
  String get settings => _s('settings');
  String get logout => _s('logout');
  String get requiredField => _s('requiredField');
  String get optional => _s('optional');
  String get notSet => _s('notSet');
  String get comingSoon => _s('comingSoon');
  String minutes(Object n) => _p('minutes', {'n': n});
  String minutesApprox(Object n) => _p('minutesApprox', {'n': n});
  String get minutesUnit => _s('minutesUnit');
  String get secondsUnit => _s('secondsUnit');
  String agoLabel(Object human) => _p('agoLabel', {'v': human});
  String get justNow => _s('justNow');

  // ------------------------------------------------------- errors (plan §2.6)
  String get errNoConnection => _s('errNoConnection');
  String get errTimeout => _s('errTimeout');
  String get errSessionExpired => _s('errSessionExpired');
  String get errInvalidCredentials => _s('errInvalidCredentials');
  String get errAccountLocked => _s('errAccountLocked');
  String get chatWithPatient => _s('chatWithPatient');
  String get chatWithFamily => _s('chatWithFamily');
  String get doctorInboxTitle => _s('doctorInboxTitle');
  String get searchPatientsAndFamily => _s('searchPatientsAndFamily');
  String get noConversationsFound => _s('noConversationsFound');
  String get heartRateNormalSinus => _s('heartRateNormalSinus');
  String get heartRateElevated => _s('heartRateElevated');
  String get errForbidden => _s('errForbidden');
  String get errServer => _s('errServer');
  String get errNotFound => _s('errNotFound');
  String get errValidation => _s('errValidation');
  String get errUnknown => _s('errUnknown');
  String get errTooManyRequests => _s('errTooManyRequests');
  String get errPayloadTooLarge => _s('errPayloadTooLarge');

  // -------------------------------------------------------- four-state shells
  String get emptyTitle => _s('emptyTitle');
  String get emptyBody => _s('emptyBody');
  String get errorTitle => _s('errorTitle');
  String get offlineTitle => _s('offlineTitle');
  String offlineSince(Object human) => _p('offlineSince', {'v': human});
  String get offlineNoData => _s('offlineNoData');
  String get savedLocallyWillSync => _s('savedLocallyWillSync');
  String get pendingSync => _s('pendingSync');

  // ------------------------------------------------------ risk states (§3.1)
  String get riskSafeTitle => _s('riskSafeTitle');
  String get riskSafeBody => _s('riskSafeBody');
  String get riskCautionTitle => _s('riskCautionTitle');
  String get riskCautionBody => _s('riskCautionBody');
  String get riskDangerTitle => _s('riskDangerTitle');
  String riskDangerBody(Object n) => _p('riskDangerBody', {'n': n});
  String get riskDangerBodyNoLead => _s('riskDangerBodyNoLead');
  String get riskUnknownTitle => _s('riskUnknownTitle');
  String get riskUnknownBody => _s('riskUnknownBody');
  String get riskUnknownWhy => _s('riskUnknownWhy');
  String get riskStale => _s('riskStale');

  // ---------------------------------------------------------------- auth
  String get loginTitle => _s('loginTitle');
  String get username => _s('username');
  String get password => _s('password');
  String get signIn => _s('signIn');
  String get signInDemo => _s('signInDemo');
  String get roleLabel => _s('roleLabel');
  String get rolePatient => _s('rolePatient');
  String get roleCaregiver => _s('roleCaregiver');
  String get roleDoctor => _s('roleDoctor');
  String get roleAdmin => _s('roleAdmin');
  String get adminHome => _s('adminHome');
  String get fullName => _s('fullName');

  // ------------------------------------------------------- patient home (§3.1)
  String get patientHome => _s('patientHome');
  String get myStatusNow => _s('myStatusNow');
  String get needHelp => _s('needHelp');
  String get needHelpConfirmTitle => _s('needHelpConfirmTitle');
  String get needHelpConfirmBody => _s('needHelpConfirmBody');
  String get send => _s('send');
  String get sosSent => _s('sosSent');
  String get sosFailed => _s('sosFailed');
  String get deviceSection => _s('deviceSection');
  String get deviceConnected => _s('deviceConnected');
  String get deviceDisconnected => _s('deviceDisconnected');
  String get deviceWaiting => _s('deviceWaiting');
  String get battery => _s('battery');
  String get signalQuality => _s('signalQuality');
  String get lastUpdate => _s('lastUpdate');
  String get nextDose => _s('nextDose');
  String get takeDose => _s('takeDose');
  String get doseTaken => _s('doseTaken');
  String get noDoseDue => _s('noDoseDue');
  String get last12h => _s('last12h');
  String get sourceSection => _s('sourceSection');
  String get sourceSimulator => _s('sourceSimulator');
  String get sourceDataset => _s('sourceDataset');
  String get sourceDevice => _s('sourceDevice');
  String get engineLabel => _s('engineLabel');
  String get engineDeep => _s('engineDeep');
  String get engineSklearn => _s('engineSklearn');
  String get engineRules => _s('engineRules');
  String get bufferedSamples => _s('bufferedSamples');
  String get manageDevice => _s('manageDevice');
  String get demoHighRisk => _s('demoHighRisk');
  String get tabHome => _s('tabHome');
  String get tabDevice => _s('tabDevice');
  String get tabAlerts => _s('tabAlerts');
  String get tabHistory => _s('tabHistory');
  String get tabMeds => _s('tabMeds');
  String get tabEmergency => _s('tabEmergency');

  // ----------------------------------------------------- active alert (§3.2)
  String get activeAlertTitle => _s('activeAlertTitle');
  String activeAlertHeadline(Object n) => _p('activeAlertHeadline', {'n': n});
  String get activeAlertHeadlineNoLead => _s('activeAlertHeadlineNoLead');
  String get cancelWindow => _s('cancelWindow');
  String get immediateSteps => _s('immediateSteps');
  String get step1 => _s('step1');
  String get step2 => _s('step2');
  String get step3 => _s('step3');
  String get imOk => _s('imOk');
  String get falseAlarm => _s('falseAlarm');
  String get notifiedFamily => _s('notifiedFamily');
  String get nobodyNotifiedYet => _s('nobodyNotifiedYet');
  String get imOkRecorded => _s('imOkRecorded');
  String get falseAlarmRecorded => _s('falseAlarmRecorded');
  String get falseAlarmWhy => _s('falseAlarmWhy');

  // ---------------------------------------------------------- history (§3.3)
  String get historyTitle => _s('historyTitle');
  String get monthlyCalendar => _s('monthlyCalendar');
  String get statsTitle => _s('statsTitle');
  String get seizuresThisMonth => _s('seizuresThisMonth');
  String get avgLeadTime => _s('avgLeadTime');
  String get falseAlarmRate => _s('falseAlarmRate');
  String get eventsTimeline => _s('eventsTimeline');
  String get triggersTitle => _s('triggersTitle');
  String get addTrigger => _s('addTrigger');
  String get triggerSleep => _s('triggerSleep');
  String get triggerStress => _s('triggerStress');
  String get triggerFatigue => _s('triggerFatigue');
  String get triggerMeals => _s('triggerMeals');
  String get triggerMenstrual => _s('triggerMenstrual');
  String get triggerFever => _s('triggerFever');
  String get triggerMissedDose => _s('triggerMissedDose');
  String get triggerNote => _s('triggerNote');
  String get triggerIntensity => _s('triggerIntensity');
  String get correlationTitle => _s('correlationTitle');
  String get correlationDisclaimer => _s('correlationDisclaimer');
  String coOccurrence(Object n) => _p('coOccurrence', {'n': n});
  String get exportPdf => _s('exportPdf');
  String get exportCsv => _s('exportCsv');
  String get reportReady => _s('reportReady');

  // -------------------------------------------------------------- meds (§3.4)
  String get medsTitle => _s('medsTitle');
  String get medName => _s('medName');
  String get dosage => _s('dosage');
  String get doseTimes => _s('doseTimes');
  String get adherenceWeek => _s('adherenceWeek');
  String get adherenceMonth => _s('adherenceMonth');
  String refillWarning(Object n) => _p('refillWarning', {'n': n});
  String get missedDoses => _s('missedDoses');
  String get shareWithDoctor => _s('shareWithDoctor');
  String get adherenceNote => _s('adherenceNote');

  // --------------------------------------------------------- emergency (§3.5)
  String get emergencyTitle => _s('emergencyTitle');
  String get emergencyOfflineNote => _s('emergencyOfflineNote');
  String get contactsSection => _s('contactsSection');
  String get addContact => _s('addContact');
  String get contactName => _s('contactName');
  String get contactPhone => _s('contactPhone');
  String get contactRelation => _s('contactRelation');
  String get callNow => _s('callNow');
  String get callFailed => _s('callFailed');
  String get priority => _s('priority');
  String get medicalCard => _s('medicalCard');
  String get diagnosis => _s('diagnosis');
  String get allergies => _s('allergies');
  String get bloodType => _s('bloodType');
  String get treatingDoctor => _s('treatingDoctor');
  String get firstAidTitle => _s('firstAidTitle');
  String get firstAid1 => _s('firstAid1');
  String get firstAid2 => _s('firstAid2');
  String get firstAid3 => _s('firstAid3');
  String get firstAid4 => _s('firstAid4');
  String get firstAid5 => _s('firstAid5');
  String get firstAidDont => _s('firstAidDont');
  String get firstAidDont1 => _s('firstAidDont1');
  String get firstAidDont2 => _s('firstAidDont2');
  String get firstAidCallAmbulance => _s('firstAidCallAmbulance');
  String get noContactsYet => _s('noContactsYet');
  String get noContactsWarning => _s('noContactsWarning');

  // ---------------------------------------------------------- settings (§3.6)
  String get settingsTitle => _s('settingsTitle');
  String get sensitivitySection => _s('sensitivitySection');
  String get sensitivityLow => _s('sensitivityLow');
  String get sensitivityMedium => _s('sensitivityMedium');
  String get sensitivityHigh => _s('sensitivityHigh');
  String get sensitivityTradeoff => _s('sensitivityTradeoff');
  String get sensitivityLowDesc => _s('sensitivityLowDesc');
  String get sensitivityMediumDesc => _s('sensitivityMediumDesc');
  String get sensitivityHighDesc => _s('sensitivityHighDesc');
  String get quietHours => _s('quietHours');
  String get quietHoursNote => _s('quietHoursNote');
  String get quietFrom => _s('quietFrom');
  String get quietTo => _s('quietTo');
  String get notifySection => _s('notifySection');
  String get notifyOnCaution => _s('notifyOnCaution');
  String get notifyOnDanger => _s('notifyOnDanger');
  String get notifyAlwaysDanger => _s('notifyAlwaysDanger');
  String get privacySection => _s('privacySection');
  String get exportMyData => _s('exportMyData');
  String get exportMyDataNote => _s('exportMyDataNote');
  String get deleteAccount => _s('deleteAccount');
  String get deleteAccountConfirm => _s('deleteAccountConfirm');
  String get appearance => _s('appearance');
  String get themeSystem => _s('themeSystem');
  String get themeLight => _s('themeLight');
  String get themeDark => _s('themeDark');
  String get language => _s('language');
  String get languageArabic => _s('languageArabic');
  String get languageEnglish => _s('languageEnglish');
  String get horizonTitle => _s('horizonTitle');
  String get horizonNote => _s('horizonNote');
  String get reduceMotionNote => _s('reduceMotionNote');

  // ------------------------------------------------------------ family (§4)
  String get familyHome => _s('familyHome');
  String get linkedPatients => _s('linkedPatients');
  String get noLinkedPatients => _s('noLinkedPatients');
  String get noLinkedPatientsBody => _s('noLinkedPatientsBody');
  String get currentLocation => _s('currentLocation');
  String get locationDisabledByPatient => _s('locationDisabledByPatient');
  String get respondTitle => _s('respondTitle');
  String sinceAlert(Object human) => _p('sinceAlert', {'v': human});
  String get directions => _s('directions');
  String get call => _s('call');
  String get message => _s('message');
  String get onMyWay => _s('onMyWay');
  String get onMyWayRecorded => _s('onMyWayRecorded');
  String get respondersSection => _s('respondersSection');
  String get seenBy => _s('seenBy');
  String get respondedBy => _s('respondedBy');
  String get onWay => _s('onWay');
  String get noRespondersYet => _s('noRespondersYet');
  String get respondersHint => _s('respondersHint');
  String get documentSeizure => _s('documentSeizure');
  String get seizureDuration => _s('seizureDuration');
  String get seizureType => _s('seizureType');
  String get seizureTypeFocal => _s('seizureTypeFocal');
  String get seizureTypeGeneralized => _s('seizureTypeGeneralized');
  String get seizureTypeAbsence => _s('seizureTypeAbsence');
  String get seizureTypeOther => _s('seizureTypeOther');
  String get seizureNotes => _s('seizureNotes');
  String get seizureLogged => _s('seizureLogged');
  String get recentEvents => _s('recentEvents');

  // --------------------------------------------------------- consents (§4.3)
  String get consentsTitle => _s('consentsTitle');
  String get consentsIntro => _s('consentsIntro');
  String get consentAlertsOnly => _s('consentAlertsOnly');
  String get consentBasic => _s('consentBasic');
  String get consentFull => _s('consentFull');
  String get consentGuardian => _s('consentGuardian');
  String get consentAlertsOnlyDesc => _s('consentAlertsOnlyDesc');
  String get consentBasicDesc => _s('consentBasicDesc');
  String get consentFullDesc => _s('consentFullDesc');
  String get consentGuardianDesc => _s('consentGuardianDesc');
  String get shareLocation => _s('shareLocation');
  String get revoke => _s('revoke');
  String get revokeConfirm => _s('revokeConfirm');
  String get revoked => _s('revoked');
  String get accessLog => _s('accessLog');
  String get accessLogEmpty => _s('accessLogEmpty');
  String get consentSaved => _s('consentSaved');

  // ----------------------------------------------------------- doctor (§5)
  String get doctorHome => _s('doctorHome');
  String get patientsList => _s('patientsList');
  String get sortNeedsAttention => _s('sortNeedsAttention');
  String get sortByName => _s('sortByName');
  String get alerts7d => _s('alerts7d');
  String get adherenceShort => _s('adherenceShort');
  String get filterNewAlerts => _s('filterNewAlerts');
  String get filterBrokenDevices => _s('filterBrokenDevices');
  String get filterLowAdherence => _s('filterLowAdherence');
  String get searchByName => _s('searchByName');
  String get patientFile => _s('patientFile');
  String get summarySection => _s('summarySection');
  String get timelineSection => _s('timelineSection');
  String get signalWindowSection => _s('signalWindowSection');
  String get analyticsSection => _s('analyticsSection');
  String get clinicalNotes => _s('clinicalNotes');
  String get clinicalNotesHint => _s('clinicalNotesHint');
  String get noteSaved => _s('noteSaved');
  String get perPatientSettings => _s('perPatientSettings');
  String get operatingPoints => _s('operatingPoints');
  String get opConservative => _s('opConservative');
  String get opBalanced => _s('opBalanced');
  String get opSensitive => _s('opSensitive');
  String get colSensitivity => _s('colSensitivity');
  String get colFalseAlarmsPerHour => _s('colFalseAlarmsPerHour');
  String opImpact(Object n) => _p('opImpact', {'n': n});
  String get thresholdSaved => _s('thresholdSaved');
  String get adjudicationTitle => _s('adjudicationTitle');
  String get adjudicationIntro => _s('adjudicationIntro');
  String get adjTrueSeizure => _s('adjTrueSeizure');
  String get adjFalseAlarm => _s('adjFalseAlarm');
  String get adjUndetermined => _s('adjUndetermined');
  String get adjSaved => _s('adjSaved');
  String get adjPending => _s('adjPending');
  String get adjNoRetrainNote => _s('adjNoRetrainNote');
  String get reportsSection => _s('reportsSection');
  String get modelPerformance => _s('modelPerformance');
  String get lastVisit => _s('lastVisit');
  String get seizureHistory => _s('seizureHistory');

  // ------------------------------------------------------------- alerts list
  String get alertsTitle => _s('alertsTitle');
  String get noAlerts => _s('noAlerts');
  String get acknowledge => _s('acknowledge');
  String get acknowledged => _s('acknowledged');
  String get severityCritical => _s('severityCritical');
  String get severityWarning => _s('severityWarning');
  String get severityPreAlert => _s('severityPreAlert');
  String get severityInfo => _s('severityInfo');

  // ------------------------------------------------------------- prediction
  String get forecastSection => _s('forecastSection');
  String get forecastResearchWarning => _s('forecastResearchWarning');
  String get preictalProb => _s('preictalProb');
  String get leadTime => _s('leadTime');
  String get forecastSourceModel => _s('forecastSourceModel');
  String get forecastSourceHeuristic => _s('forecastSourceHeuristic');
  String get forecastHeuristicWarning => _s('forecastHeuristicWarning');
  String get drivers => _s('drivers');
  String get driverEeg => _s('driverEeg');
  String get driverHr => _s('driverHr');
  String get driverMotion => _s('driverMotion');
  String get driverEcg => _s('driverEcg');

  // ------------------------------------------------- screen-level additions
  // Added while implementing §3–§5. Grouped by the screen that needs them so a
  // translator can work one screen at a time.

  // common
  String get confirm => _s('confirm');
  String get saved => _s('saved');
  String get deleted => _s('deleted');
  String get copied => _s('copied');
  String get today => _s('today');
  String get yesterday => _s('yesterday');
  String get patientLabel => _s('patientLabel');
  String get caregiverLabel => _s('caregiverLabel');
  String get noteLabel => _s('noteLabel');
  String get moveUp => _s('moveUp');
  String get moveDown => _s('moveDown');
  String get confirmDelete => _s('confirmDelete');
  String get quickActions => _s('quickActions');
  String get requestQueued => _s('requestQueued');

  // auth
  String get appTagline => _s('appTagline');
  String get showPassword => _s('showPassword');
  String get hidePassword => _s('hidePassword');
  String get demoNote => _s('demoNote');
  String get demoUserName => _s('demoUserName');
  String get signInFailed => _s('signInFailed');

  // history
  String get noHistoryYet => _s('noHistoryYet');
  String get calendarLegendSafe => _s('calendarLegendSafe');
  String get calendarLegendCaution => _s('calendarLegendCaution');
  String get calendarLegendDanger => _s('calendarLegendDanger');
  String get prevMonth => _s('prevMonth');
  String get nextMonth => _s('nextMonth');
  String get noEventsThisMonth => _s('noEventsThisMonth');
  String get exportFailed => _s('exportFailed');

  // triggers
  String get triggerKind => _s('triggerKind');
  String get triggerOther => _s('triggerOther');
  String get triggerLogged => _s('triggerLogged');
  String get triggerHistory => _s('triggerHistory');

  // emergency
  String get contactsHint => _s('contactsHint');
  String get contactSaved => _s('contactSaved');
  String get medicalCardSaved => _s('medicalCardSaved');
  String get medicalCardEmpty => _s('medicalCardEmpty');
  String get doctorPhone => _s('doctorPhone');
  String get notesLabel => _s('notesLabel');
  String get medicalLockScreen => _s('medicalLockScreen');
  String get lockScreenHint => _s('lockScreenHint');
  String get copyMedicalCard => _s('copyMedicalCard');
  String get editMedicalCard => _s('editMedicalCard');

  // settings
  String get sensitivitySaved => _s('sensitivitySaved');
  String get exportStarted => _s('exportStarted');
  String get deleteAccountNote => _s('deleteAccountNote');

  // family
  String get openPatient => _s('openPatient');
  String get respond => _s('respond');
  String get noPatientSelected => _s('noPatientSelected');
  String get locationUnavailable => _s('locationUnavailable');
  String get arrived => _s('arrived');
  String get alertTime => _s('alertTime');
  String get lastKnownStatus => _s('lastKnownStatus');

  // consents
  String get addConsent => _s('addConsent');
  String get noConsentsYet => _s('noConsentsYet');
  String get consentLevelLabel => _s('consentLevelLabel');

  // doctor
  String get attentionNeeded => _s('attentionNeeded');
  String get noPatientsYet => _s('noPatientsYet');
  String get operatingPointNote => _s('operatingPointNote');
  String get applyThreshold => _s('applyThreshold');
  String get noAdjudicationsPending => _s('noAdjudicationsPending');
  String get verdictLabel => _s('verdictLabel');
  String get openFile => _s('openFile');

  // active alert
  String get alertNotFound => _s('alertNotFound');

  // medication reminders (raised from a service, with no BuildContext)
  String get medReminderTitle => _s('medReminderTitle');
  String medReminderBody(String name, String time) =>
      _p('medReminderBody', {'name': name, 'time': time});
  String get scheduleDaily => _s('scheduleDaily');

  // calendar + charts
  //
  // Month and weekday names live in the table rather than coming from `intl`'s
  // `DateFormat`, which needs `initializeDateFormatting()` and pulls locale data
  // at runtime. Seven and twelve short strings are cheaper and cannot fail.
  String get weekdayInitials => _s('weekdayInitials');
  String get monthNames => _s('monthNames');
  List<String> get weekdayLabels => weekdayInitials.split(',');
  String monthName(int month) {
    final names = monthNames.split(',');
    if (month < 1 || month > names.length) return '$month';
    return names[month - 1];
  }

  String monthYear(int year, int month) => '${monthName(month)} $year';
  String get chartNoData => _s('chartNoData');
  String get totalAlerts => _s('totalAlerts');

  // access log — `action` is stored as a stable key so the row keeps its meaning
  // when the app language changes; the sentence is chosen here, at paint time.
  String accessAction(String action) => switch (action) {
    'viewed_status' => _s('accessViewedStatus'),
    'viewed_history' => _s('accessViewedHistory'),
    'viewed_meds' => _s('accessViewedMeds'),
    'consent_changed' => _s('accessConsentChanged'),
    'consent_revoked' => _s('accessConsentRevoked'),
    'alert_response' => _s('accessAlertResponse'),
    'exported' => _s('accessExported'),
    _ => action,
  };

  // medications screen
  String get noMedsYet => _s('noMedsYet');
  String get addMedication => _s('addMedication');
  String get pauseMed => _s('pauseMed');
  String get resumeMed => _s('resumeMed');
  String get medPaused => _s('medPaused');
  String get takenAt => _s('takenAt');
  String get dueAt => _s('dueAt');
  String get todayPlan => _s('todayPlan');

  // model metrics panel (#20) — the offline evaluation shown to the doctor
  String get liveEngine => _s('liveEngine');
  String get modelAvailableOffline => _s('modelAvailableOffline');
  String get metricsUnavailable => _s('metricsUnavailable');
  String get taskPrediction => _s('taskPrediction');
  String get taskDetection => _s('taskDetection');
  String get perWindow => _s('perWindow');
  String get colSpecificity => _s('colSpecificity');
  String get colThreshold => _s('colThreshold');
  String get modelNotTrained => _s('modelNotTrained');
  String get modelBadFormat => _s('modelBadFormat');

  // prediction-event audit trail (#19)
  String predictionEventsCount(Object n) =>
      _p('predictionEventsCount', {'n': n});
  String get noPredictionEvents => _s('noPredictionEvents');
  String get outcomeEscalated => _s('outcomeEscalated');
  String get outcomeFalseAlarm => _s('outcomeFalseAlarm');
  String get outcomeOnsetConfirmed => _s('outcomeOnsetConfirmed');
  String get outcomePending => _s('outcomePending');
  String get escalatedShort => _s('escalatedShort');
  String get horizonShort => _s('horizonShort');

  // signal-source screen
  String get deviceIntro => _s('deviceIntro');
  String get currentSource => _s('currentSource');
  String get sourceSimulatorDesc => _s('sourceSimulatorDesc');
  String get sourceDatasetDesc => _s('sourceDatasetDesc');
  String get sourceDeviceDesc => _s('sourceDeviceDesc');
  String get recommendedNow => _s('recommendedNow');
  String get serverSettings => _s('serverSettings');
  String get demoPathTitle => _s('demoPathTitle');
  String get demoPathSteps => _s('demoPathSteps');

  // background notifications (built in the services, where there is no context)
  String get notificationFallbackTitle => _s('notificationFallbackTitle');
  String get adminUsesWebPanel => _s('adminUsesWebPanel');
  String get thePatient => _s('thePatient');
  String get sosMessageSuffix => _s('sosMessageSuffix');
  String locationIs(Object url) => _p('locationIs', {'url': url});
  String get highRiskNotification => _s('highRiskNotification');
  String get preAlertCancelWindowNote => _s('preAlertCancelWindowNote');
  String get preAlertNotCancelled => _s('preAlertNotCancelled');
  String withinMinutes(Object n) => _p('withinMinutes', {'n': n});

  // biometrics & security
  String get biometricPromptReason => _s('biometricPromptReason');
  String get autoLockTitle => _s('autoLockTitle');
  String get autoLockMessage => _s('autoLockMessage');
  String get unlockWithBiometrics => _s('unlockWithBiometrics');
  String get biometricsEnabled => _s('biometricsEnabled');
  String get biometricsEnabledDesc => _s('biometricsEnabledDesc');

  // change password
  String get changePassword => _s('changePassword');
  String get currentPassword => _s('currentPassword');
  String get newPassword => _s('newPassword');
  String get confirmPassword => _s('confirmPassword');
  String get passwordChangedSuccess => _s('passwordChangedSuccess');
  String get passwordMismatch => _s('passwordMismatch');

  // reports & excel export
  String get reportsTitle => _s('reportsTitle');
  String get exportExcel => _s('exportExcel');
  String get exportPdfReport => _s('exportPdfReport');
  String get filterAll => _s('filterAll');
  String get filterSeizures => _s('filterSeizures');
  String get filterAlerts => _s('filterAlerts');
  String get filterMedications => _s('filterMedications');

  // exit dialog & background
  String get exitConfirmTitle => _s('exitConfirmTitle');
  String get exitConfirmMessage => _s('exitConfirmMessage');
  String get keepInBackground => _s('keepInBackground');
  String get exitApp => _s('exitApp');

  // clinical messages
  String get messagesTitle => _s('messagesTitle');
  String get typeMessage => _s('typeMessage');
  String get repliesDisabledByDoctor => _s('repliesDisabledByDoctor');
  String get logoutConfirmBody => _s('logoutConfirmBody');
  String get simulatorTitle => _s('simulatorTitle');
  String get openPatientNavigation => _s('openPatientNavigation');
  String get patientLocationAvailable => _s('patientLocationAvailable');
  String get patientLocationAvailableSub => _s('patientLocationAvailableSub');
  String get patientDirectPhone => _s('patientDirectPhone');
  String get preAlertSimulatorStarted => _s('preAlertSimulatorStarted');
  String get preAlertActiveBanner => _s('preAlertActiveBanner');
  String get preAlertCountdownSuffix => _s('preAlertCountdownSuffix');
}

// ---------------------------------------------------------------------------
// Arabic — the primary table. Every key must exist here; `_s` falls back to it
// when another locale is missing an entry, so Arabic is the safety net.
// ---------------------------------------------------------------------------
const Map<String, String> _ar = {
  'appTitle': 'درع الأعصاب الذكي',
  'appSubtitle': 'بوابة الوصول السريرية الموحدة — الذكاء الاصطناعي والتنبؤ المبكر',
  'ok': 'حسناً',
  'cancel': 'إلغاء',
  'save': 'حفظ',
  'delete': 'حذف',
  'edit': 'تعديل',
  'add': 'إضافة',
  'close': 'إغلاق',
  'retry': 'إعادة المحاولة',
  'back': 'رجوع',
  'yes': 'نعم',
  'no': 'لا',
  'loading': 'جارٍ التحميل…',
  'search': 'بحث',
  'all': 'الكل',
  'none': 'لا شيء',
  'unknown': 'غير معروف',
  'refresh': 'تحديث',
  'export': 'تصدير',
  'settings': 'الإعدادات',
  'logout': 'تسجيل الخروج',
  'requiredField': 'هذا الحقل مطلوب',
  'optional': 'اختياري',
  'notSet': 'غير محدد',
  'comingSoon': 'غير متاح بعد',
  'minutes': '{n} دقيقة',
  'minutesApprox': '~{n} دقيقة',
  'minutesUnit': 'دقيقة',
  'secondsUnit': 'ثانية',
  'agoLabel': 'قبل {v}',
  'justNow': 'الآن',

  'errNoConnection': 'لا يوجد اتصال. سنحاول تلقائياً.',
  'errTimeout': 'الخادم بطيء الاستجابة.',
  'errSessionExpired': 'انتهت الجلسة. سجّل الدخول مرة أخرى.',
  'errInvalidCredentials': 'اسم المستخدم أو كلمة المرور غير صحيحة.',
  'errAccountLocked': 'تم قفل الحساب مؤقتاً لمدة 15 دقيقة لكثرة المحاولات الخاطئة لحماية أمانك.',
  'chatWithPatient': 'المحادثة المباشرة مع المريض',
  'chatWithFamily': 'المحادثة مع الأسرة والمرافق',
  'doctorInboxTitle': 'صندوق المحادثات السريرية',
  'searchPatientsAndFamily': 'بحث عن مريض أو مرافق...',
  'noConversationsFound': 'لم يتم العثور على محادثات مطابقة',
  'heartRateNormalSinus': 'إيقاع جيبي طبيعي (منتظم) · 60-100 نبضة/د',
  'heartRateElevated': 'تسارع نبضات القلب (تنبيه) · أعلى من 100 نبضة/د',
  'errForbidden': 'لا تملك صلاحية لهذا الإجراء.',
  'errServer': 'خلل مؤقت لدينا، لا علاقة له ببياناتك.',
  'errNotFound': 'العنصر المطلوب غير موجود.',
  'errValidation': 'بعض البيانات غير مكتملة أو غير صحيحة.',
  'errUnknown': 'حدث خطأ غير متوقع. أعد المحاولة.',
  'errTooManyRequests': 'طلبات كثيرة في وقت قصير. انتظر لحظة.',
  'errPayloadTooLarge': 'حجم البيانات كبير جداً.',

  'emptyTitle': 'لا توجد بيانات بعد',
  'emptyBody': 'ستظهر البيانات هنا بمجرد توفّرها.',
  'errorTitle': 'تعذّر إكمال العملية',
  'offlineTitle': 'غير متصل',
  'offlineSince': 'غير متصل — آخر تحديث {v}',
  'offlineNoData': 'غير متصل ولا توجد بيانات محفوظة.',
  'savedLocallyWillSync': 'حُفظ على الجهاز، وسيُرسل عند عودة الاتصال.',
  'pendingSync': 'بانتظار المزامنة',

  'riskSafeTitle': 'الوضع مستقر',
  'riskSafeBody': 'لا توجد مؤشرات على اقتراب نوبة الآن.',
  'riskCautionTitle': 'ارتفاع طفيف',
  'riskCautionBody': 'كن قريباً من مكان آمن ومن شخص تعرفه.',
  'riskDangerTitle': 'احتمال مرتفع',
  'riskDangerBody': 'احتمال نوبة خلال ~{n} دقيقة. اجلس في مكان آمن الآن.',
  'riskDangerBodyNoLead': 'احتمال نوبة مرتفع. اجلس في مكان آمن الآن.',
  'riskUnknownTitle': 'لا توجد بيانات كافية',
  'riskUnknownBody':
      'لا نستطيع تقييم حالتك الآن، ولن نقول إنك بأمان دون بيانات.',
  'riskUnknownWhy': 'السبب: الجهاز غير متصل أو لم تصل قراءة حديثة.',
  'riskStale': 'آخر قراءة قديمة',

  'loginTitle': 'تسجيل الدخول',
  'username': 'اسم المستخدم',
  'password': 'كلمة المرور',
  'signIn': 'دخول',
  'signInDemo': 'دخول تجريبي',
  'roleLabel': 'الدور',
  'rolePatient': 'مريض',
  'roleCaregiver': 'أحد أفراد الأسرة',
  'roleDoctor': 'طبيب',
  'roleAdmin': 'مدير النظام',
  'adminHome': 'لوحة تحكم المدير',
  'fullName': 'الاسم الكامل',

  'patientHome': 'حالتي',
  'myStatusNow': 'حالتي الآن',
  'needHelp': 'أحتاج مساعدة',
  'needHelpConfirmTitle': 'طلب مساعدة؟',
  'needHelpConfirmBody':
      'سيتم إبلاغ أفراد أسرتك والطبيب فوراً، مع موقعك إن كان متاحاً.',
  'send': 'إرسال',
  'sosSent': 'تم إبلاغ من يستطيع مساعدتك',
  'sosFailed': 'تعذّر إرسال الطلب — أعد المحاولة أو اتصل مباشرة',
  'deviceSection': 'الجهاز',
  'deviceConnected': 'متصل',
  'deviceDisconnected': 'غير متصل',
  'deviceWaiting': 'بانتظار الإرسال',
  'battery': 'البطارية',
  'signalQuality': 'جودة الإشارة',
  'lastUpdate': 'آخر تحديث',
  'nextDose': 'الجرعة القادمة',
  'takeDose': 'تناولته',
  'doseTaken': 'تم تسجيل الجرعة',
  'noDoseDue': 'لا توجد جرعة قريبة',
  'last12h': 'آخر ١٢ ساعة',
  'sourceSection': 'مصدر البيانات',
  'sourceSimulator': 'محاكاة',
  'sourceDataset': 'مجموعة بيانات',
  'sourceDevice': 'جهاز الرأس',
  'engineLabel': 'محرك التحليل',
  'engineDeep': 'تعلّم عميق (CNN-LSTM)',
  'engineSklearn': 'تعلّم آلي (احتياطي)',
  'engineRules': 'قواعد استدلال (احتياطي)',
  'bufferedSamples': 'عيّنات مستلمة',
  'manageDevice': 'إدارة الجهاز',
  'demoHighRisk': 'محاكاة خطر مرتفع',
  'tabHome': 'الرئيسية',
  'tabDevice': 'الجهاز',
  'tabAlerts': 'التنبيهات',
  'tabHistory': 'السجل',
  'tabMeds': 'الدواء',
  'tabEmergency': 'الطوارئ',

  'activeAlertTitle': 'تنبيه نشط',
  'activeAlertHeadline': 'احتمال نوبة خلال ~{n} دقيقة',
  'activeAlertHeadlineNoLead': 'احتمال نوبة مرتفع',
  'cancelWindow': 'إن كنت بخير، أَلغِ التنبيه قبل انتهاء العدّاد',
  'immediateSteps': 'افعل هذا الآن',
  'step1': 'اجلس أو استلقِ في مكان آمن.',
  'step2': 'أبلغ من حولك أنك قد تتعرض لنوبة.',
  'step3': 'ابتعد عن الدرج والماء والأدوات الحادة.',
  'imOk': 'أنا بخير',
  'falseAlarm': 'تنبيه خاطئ',
  'notifiedFamily': 'من تم إبلاغه',
  'nobodyNotifiedYet': 'لم يتم إبلاغ أحد بعد',
  'imOkRecorded': 'تم التسجيل — لن يُرسل إنذار',
  'falseAlarmRecorded': 'شكراً، سُجّل كإنذار خاطئ',
  'falseAlarmWhy':
      'تسجيلك للإنذارات الخاطئة هو ما يقيس دقة النظام فعلياً، وليس مجرد زر.',

  'historyTitle': 'السجل والتحليلات',
  'monthlyCalendar': 'التقويم الشهري',
  'statsTitle': 'إحصاءات',
  'seizuresThisMonth': 'نوبات هذا الشهر',
  'avgLeadTime': 'متوسط زمن الاستباق',
  'falseAlarmRate': 'نسبة الإنذارات الخاطئة',
  'eventsTimeline': 'خط الأحداث',
  'triggersTitle': 'مذكرات المحفزات',
  'addTrigger': 'إضافة محفّز',
  'triggerSleep': 'قلة نوم',
  'triggerStress': 'ضغط نفسي',
  'triggerFatigue': 'إجهاد',
  'triggerMeals': 'وجبة فائتة',
  'triggerMenstrual': 'الدورة الشهرية',
  'triggerFever': 'حمّى',
  'triggerMissedDose': 'جرعة فائتة',
  'triggerNote': 'ملاحظة',
  'triggerIntensity': 'الشدة',
  'correlationTitle': 'تزامن المحفزات مع الأحداث',
  'correlationDisclaimer':
      'ما يظهر هنا **تزامن** لا **سبب**. لا يصلح لاتخاذ قرار دوائي؛ اعرضه على طبيبك.',
  'coOccurrence': 'لوحظ تزامن في {n} حالة',
  'exportPdf': 'تصدير PDF',
  'exportCsv': 'تصدير CSV',
  'reportReady': 'التقرير جاهز',

  'medsTitle': 'الأدوية',
  'medName': 'اسم الدواء',
  'dosage': 'الجرعة',
  'doseTimes': 'أوقات الجرعات',
  'adherenceWeek': 'الالتزام هذا الأسبوع',
  'adherenceMonth': 'الالتزام هذا الشهر',
  'refillWarning': 'تبقّى {n} يوم من الدواء',
  'missedDoses': 'جرعات فائتة',
  'shareWithDoctor': 'مشاركة نسبة الالتزام مع الطبيب',
  'adherenceNote':
      'عدم الالتزام الدوائي من أكثر أسباب تكرار النوبات — هذه الشاشة قد تكون أنفع لك من التنبؤ نفسه.',

  'emergencyTitle': 'خطة الطوارئ',
  'emergencyOfflineNote':
      'هذه الشاشة تعمل بالكامل دون إنترنت. وقت الحاجة إليها هو أسوأ وقت للاعتماد على الشبكة.',
  'contactsSection': 'جهات الاتصال',
  'addContact': 'إضافة جهة اتصال',
  'contactName': 'الاسم',
  'contactPhone': 'رقم الهاتف',
  'contactRelation': 'صلة القرابة',
  'callNow': 'اتصال',
  'callFailed': 'تعذّر بدء الاتصال — اتصل يدوياً',
  'priority': 'الأولوية',
  'medicalCard': 'البطاقة الطبية',
  'diagnosis': 'التشخيص',
  'allergies': 'الحساسية',
  'bloodType': 'فصيلة الدم',
  'treatingDoctor': 'الطبيب المعالج',
  'firstAidTitle': 'الإسعاف أثناء النوبة',
  'firstAid1': 'ابقَ مع المريض واحفظ الوقت من بداية النوبة.',
  'firstAid2': 'أبعد الأشياء الصلبة والحادة عنه.',
  'firstAid3': 'ضع شيئاً طرياً تحت رأسه.',
  'firstAid4': 'أَدِرْه على جانبه لتسهيل التنفس.',
  'firstAid5': 'فُكّ ما يضيق على رقبته.',
  'firstAidDont': 'لا تفعل',
  'firstAidDont1': 'لا تضع شيئاً في فمه.',
  'firstAidDont2': 'لا تحاول تثبيته بالقوة.',
  'firstAidCallAmbulance':
      'اطلب الإسعاف إذا زادت النوبة عن ٥ دقائق، أو تكررت، أو لم يستعد وعيه، أو أُصيب، أو كانت أول نوبة له.',
  'noContactsYet': 'لا توجد جهات اتصال',
  'noContactsWarning':
      'أضف جهة اتصال واحدة على الأقل. بدونها لا يعرف التطبيق بمن يتصل.',

  'settingsTitle': 'الإعدادات',
  'sensitivitySection': 'حساسية التنبيه',
  'sensitivityLow': 'منخفضة',
  'sensitivityMedium': 'متوسطة',
  'sensitivityHigh': 'عالية',
  'sensitivityTradeoff': 'حساسية أعلى = تنبيه أبكر + إنذارات خاطئة أكثر.',
  'sensitivityLowDesc': 'تنبيهات أقل، واحتمال أكبر لتفويت نوبة.',
  'sensitivityMediumDesc': 'توازن بين الإنذار المبكر وعدد الإنذارات الخاطئة.',
  'sensitivityHighDesc': 'تنبيه أبكر، مع إنذارات خاطئة أكثر بشكل ملحوظ.',
  'quietHours': 'ساعات الهدوء',
  'quietHoursNote':
      'تُكتم التنبيهات غير العاجلة في هذه الساعات. تنبيهات الخطر المرتفع تتجاوزها دائماً.',
  'quietFrom': 'من',
  'quietTo': 'إلى',
  'notifySection': 'من يُبلَّغ',
  'notifyOnCaution': 'إبلاغ الأسرة عند «ارتفاع طفيف»',
  'notifyOnDanger': 'إبلاغ الأسرة عند «احتمال مرتفع»',
  'notifyAlwaysDanger': 'إبلاغ الخطر المرتفع لا يمكن إيقافه.',
  'privacySection': 'الخصوصية',
  'exportMyData': 'تصدير بياناتي',
  'exportMyDataNote': 'نسخة من سجلك وأدويتك وأحداثك، بصيغة يمكنك الاحتفاظ بها.',
  'deleteAccount': 'حذف حسابي',
  'deleteAccountConfirm':
      'سيُحذف حسابك وبياناتك المحلية. لا يمكن التراجع. متأكد؟',
  'appearance': 'المظهر',
  'themeSystem': 'حسب النظام',
  'themeLight': 'نهاري',
  'themeDark': 'ليلي',
  'language': 'اللغة',
  'languageArabic': 'العربية',
  'languageEnglish': 'English',
  'horizonTitle': 'أفق التنبؤ (SPH)',
  'horizonNote':
      'المدة التي يحاول النظام التنبؤ بالنوبة قبلها. تُطبَّق على التنبؤ دون اتصال والمحاكاة؛ أما الخادم فيستخدم PREICTAL_HORIZON_MIN.',
  'reduceMotionNote':
      'التطبيق يتبع إعداد «تقليل الحركة» في نظامك، ولا يستخدم وميضاً ولا رسوماً سريعة.',

  'familyHome': 'متابعة الأسرة',
  'linkedPatients': 'المرضى المرتبطون',
  'noLinkedPatients': 'لا يوجد مرضى مرتبطون',
  'noLinkedPatientsBody':
      'يجب أن يمنحك المريض صلاحية المتابعة من إعدادات حسابه.',
  'currentLocation': 'الموقع الحالي',
  'locationDisabledByPatient': 'المريض أوقف مشاركة الموقع',
  'respondTitle': 'الاستجابة للتنبيه',
  'sinceAlert': 'منذ التنبيه: {v}',
  'directions': 'الاتجاهات',
  'call': 'اتصال',
  'message': 'رسالة',
  'onMyWay': 'أنا في الطريق',
  'onMyWayRecorded': 'أُبلغ الآخرون أنك في الطريق',
  'respondersSection': 'حالة الأسرة',
  'seenBy': 'رأى التنبيه',
  'respondedBy': 'استجاب',
  'onWay': 'في الطريق',
  'noRespondersYet': 'لم يستجب أحد بعد',
  'respondersHint':
      'يمنع هذا أن يظن الجميع أن غيرهم ذاهب، أو أن يذهب الجميع دفعة واحدة.',
  'documentSeizure': 'توثيق النوبة',
  'seizureDuration': 'مدة النوبة (بالثواني)',
  'seizureType': 'نوع النوبة',
  'seizureTypeFocal': 'بؤرية',
  'seizureTypeGeneralized': 'معمّمة',
  'seizureTypeAbsence': 'غيبة',
  'seizureTypeOther': 'أخرى',
  'seizureNotes': 'ملاحظات',
  'seizureLogged': 'تم توثيق النوبة',
  'recentEvents': 'آخر الأحداث',

  'consentsTitle': 'صلاحيات الأسرة',
  'consentsIntro':
      'أنت تقرر من يرى ماذا. يمكنك سحب أي صلاحية في أي وقت وبلا تبرير.',
  'consentAlertsOnly': 'تنبيهات فقط',
  'consentBasic': 'مراقبة أساسية',
  'consentFull': 'مراقبة كاملة',
  'consentGuardian': 'وصي',
  'consentAlertsOnlyDesc': 'التنبيهات العاجلة لا غير.',
  'consentBasicDesc': 'التنبيهات + حالتك الحالية وحالة الجهاز.',
  'consentFullDesc': 'ما سبق + السجل والأدوية.',
  'consentGuardianDesc': 'كل شيء + صلاحية التعديل. للقاصر بولاية موثقة.',
  'shareLocation': 'مشاركة موقعي عند التنبيه',
  'revoke': 'سحب الصلاحية',
  'revokeConfirm': 'سحب صلاحية هذا الشخص؟ لن يرى بياناتك بعد الآن.',
  'revoked': 'تم سحب الصلاحية',
  'accessLog': 'سجل الوصول',
  'accessLogEmpty': 'لم يطّلع أحد على بياناتك بعد',
  'consentSaved': 'تم حفظ الصلاحية',

  'doctorHome': 'لوحة الطبيب',
  'patientsList': 'المرضى',
  'sortNeedsAttention': 'الأكثر حاجة للانتباه',
  'sortByName': 'حسب الاسم',
  'alerts7d': 'تنبيهات ٧ أيام',
  'adherenceShort': 'الالتزام',
  'filterNewAlerts': 'تنبيهات جديدة',
  'filterBrokenDevices': 'أجهزة معطلة',
  'filterLowAdherence': 'التزام منخفض',
  'searchByName': 'بحث بالاسم أو رقم الملف',
  'patientFile': 'ملف المريض',
  'summarySection': 'ملخص',
  'timelineSection': 'الخط الزمني',
  'signalWindowSection': 'نافذة الإشارة',
  'analyticsSection': 'التحليلات',
  'clinicalNotes': 'الملاحظات السريرية',
  'clinicalNotesHint': 'ملاحظات خاصة بك، لا يراها المريض.',
  'noteSaved': 'حُفظت الملاحظة',
  'perPatientSettings': 'إعدادات هذا المريض',
  'operatingPoints': 'نقاط التشغيل',
  'opConservative': 'متحفظ',
  'opBalanced': 'متوازن',
  'opSensitive': 'حساس',
  'colSensitivity': 'الحساسية',
  'colFalseAlarmsPerHour': 'إنذارات كاذبة/ساعة',
  'opImpact': 'هذا الإعداد يعني تنبيهاً خاطئاً كل ~{n} ساعة تقريباً.',
  'thresholdSaved': 'حُفظ إعداد الحساسية',
  'adjudicationTitle': 'مراجعة الأحداث',
  'adjudicationIntro':
      'تصنيفك لكل تنبيه هو ما يقيس دقة النظام في الاستخدام الفعلي، لا في مجموعة الاختبار.',
  'adjTrueSeizure': 'نوبة حقيقية',
  'adjFalseAlarm': 'إنذار كاذب',
  'adjUndetermined': 'غير محدد',
  'adjSaved': 'تم حفظ المراجعة',
  'adjPending': 'بانتظار المراجعة',
  'adjNoRetrainNote':
      'هذه المراجعات تُجمع وتُصدَّر فقط. لا يُعاد تدريب النموذج تلقائياً منها؛ أي إعادة تدريب تمر بمراجعة بشرية كاملة.',
  'reportsSection': 'التقارير',
  'modelPerformance': 'مقاييس دقة وأداء النموذج (اختبار مرجعي سريري)',
  'lastVisit': 'آخر زيارة',
  'seizureHistory': 'تاريخ النوبات',

  'alertsTitle': 'التنبيهات',
  'noAlerts': 'لا توجد تنبيهات',
  'acknowledge': 'إقرار',
  'acknowledged': 'تم الإقرار',
  'severityCritical': 'عاجل',
  'severityWarning': 'تحذير',
  'severityPreAlert': 'تنبيه مبكر',
  'severityInfo': 'معلومة',

  'forecastSection': 'التنبؤ',
  'forecastResearchWarning': 'درجة بحثية غير معتمدة طبيًا، وليست احتمالًا مُعايرًا لحدوث نوبة. لا يمكن تقدير وقت النوبة من هذه الدرجة أو الاعتماد عليها لاتخاذ قرار علاجي.',
  'preictalProb': 'درجة النموذج التجريبية',
  'leadTime': 'زمن الاستباق',
  'forecastSourceModel': 'نموذج تنبؤ عصبي (CNN-LSTM)',
  'forecastSourceHeuristic': 'محاكاة تنبؤية',
  'forecastHeuristicWarning':
      'هذا التنبؤ مُحاكى لأغراض العرض، وليس ناتج نموذج مدرَّب على بيانات مرضى.',
  'drivers': 'ما الذي رفع الاحتمال',
  'driverEeg': 'إشارة الدماغ',
  'driverHr': 'نبض القلب',
  'driverMotion': 'الحركة',
  'driverEcg': 'تخطيط القلب',

  // --- screen-level additions (§3–§5) ---
  'confirm': 'تأكيد',
  'saved': 'تم الحفظ',
  'deleted': 'تم الحذف',
  'copied': 'تم النسخ',
  'today': 'اليوم',
  'yesterday': 'أمس',
  'patientLabel': 'المريض',
  'caregiverLabel': 'أحد الأقارب',
  'noteLabel': 'ملاحظة',
  'moveUp': 'تقديم في الترتيب',
  'moveDown': 'تأخير في الترتيب',
  'confirmDelete': 'هل تريد حذف هذا العنصر؟',
  'quickActions': 'إجراءات سريعة',
  'requestQueued': 'تم تسجيل الطلب، وسيُرسل عند توفّر الاتصال.',

  'appTagline': 'مراقبة مرضى الصرع والتنبؤ المبكر بالنوبات',
  'showPassword': 'إظهار كلمة المرور',
  'hidePassword': 'إخفاء كلمة المرور',
  'demoNote': 'الحسابات الحقيقية تُنشأ من لوحة الإدارة. وضع العرض يعمل دون حساب.',
  'demoUserName': 'مستخدم تجريبي',
  'signInFailed': 'تعذّر تسجيل الدخول',

  'noHistoryYet': 'لا توجد أحداث مسجّلة بعد.',
  'calendarLegendSafe': 'يوم دون تنبيهات',
  'calendarLegendCaution': 'يوم فيه تنبيه انتباه',
  'calendarLegendDanger': 'يوم فيه تنبيه خطر',
  'prevMonth': 'الشهر السابق',
  'nextMonth': 'الشهر التالي',
  'noEventsThisMonth': 'لا أحداث في هذا الشهر.',
  'exportFailed': 'تعذّر إنشاء التقرير.',

  'triggerKind': 'نوع المُحفّز',
  'triggerOther': 'أخرى',
  'triggerLogged': 'تم تسجيل المُحفّز.',
  'triggerHistory': 'المُحفّزات المسجّلة',

  'contactsHint': 'الأقرب أولاً — اتصال بلمسة واحدة.',
  'contactSaved': 'تم حفظ جهة الاتصال.',
  'medicalCardSaved': 'تم حفظ البطاقة الطبية.',
  'medicalCardEmpty': 'لم تُدخل بيانات البطاقة الطبية بعد.',
  'doctorPhone': 'هاتف الطبيب',
  'notesLabel': 'ملاحظات',
  'medicalLockScreen': 'شاشة طبية للطوارئ',
  'lockScreenHint': 'اعرض هذه الشاشة لمن يساعدك.',
  'copyMedicalCard': 'نسخ البطاقة',
  'editMedicalCard': 'تعديل البطاقة',

  'sensitivitySaved': 'تم حفظ مستوى الحساسية.',
  'exportStarted': 'جارٍ تجهيز نسخة من بياناتك.',
  'deleteAccountNote':
      'يُنفَّذ حذف الحساب من الإدارة بعد التحقق من هويتك، وتبقى السجلات الطبية اللازمة قانونياً.',

  'openPatient': 'فتح ملف المريض',
  'respond': 'استجابة',
  'noPatientSelected': 'لم يُحدَّد مريض.',
  'locationUnavailable': 'الموقع غير متوفر الآن.',
  'arrived': 'وصلت',
  'alertTime': 'وقت التنبيه',
  'lastKnownStatus': 'آخر حالة معروفة',

  'addConsent': 'إضافة صلاحية',
  'noConsentsYet': 'لم تمنح أي صلاحية بعد.',
  'consentLevelLabel': 'مستوى الصلاحية',

  'attentionNeeded': 'يحتاج متابعة',
  'noPatientsYet': 'لا مرضى مرتبطون بحسابك.',
  'operatingPointNote':
      'اختيار نقطة التشغيل موازنة: حساسية أعلى تعني كشفاً أكثر وإنذارات خاطئة أكثر.',
  'applyThreshold': 'تطبيق',
  'noAdjudicationsPending': 'لا تنبيهات تنتظر التصنيف.',
  'verdictLabel': 'التصنيف',
  'openFile': 'فتح الملف',

  'alertNotFound': 'انتهى هذا التنبيه أو لم يعد متوفراً.',

  'medReminderTitle': 'تذكير بالدواء',
  'medReminderBody': 'حان موعد {name} الساعة {time}.',
  'scheduleDaily': 'يومي',

  'weekdayInitials': 'أحد,اثن,ثلا,أرب,خمي,جمع,سبت',
  'monthNames':
      'يناير,فبراير,مارس,أبريل,مايو,يونيو,يوليو,أغسطس,سبتمبر,أكتوبر,نوفمبر,ديسمبر',
  'chartNoData': 'لا توجد بيانات إشارة بعد.',
  'totalAlerts': 'إجمالي التنبيهات',

  'accessViewedStatus': 'اطّلع على حالتك',
  'accessViewedHistory': 'اطّلع على سجلك',
  'accessViewedMeds': 'اطّلع على أدويتك',
  'accessConsentChanged': 'تغيّرت صلاحيته',
  'accessConsentRevoked': 'سُحبت صلاحيته',
  'accessAlertResponse': 'استجاب لتنبيه',
  'accessExported': 'صدّر نسخة من البيانات',

  'noMedsYet': 'لا أدوية مسجّلة بعد.',
  'addMedication': 'إضافة دواء',
  'pauseMed': 'إيقاف مؤقت',
  'resumeMed': 'إعادة التشغيل',
  'medPaused': 'موقوف مؤقتاً',
  'takenAt': 'أُخذت',
  'dueAt': 'موعدها',
  'todayPlan': 'خطة اليوم',

  // لوحة مقاييس النموذج. النص يقول أي محرّك يعمل الآن، لأن عرض مقاييس نموذج
  // مُدرَّب بجوار تنبؤ مصدره محاكاة استدلالية يوحي بأن الأرقام تصف ما يراه المريض.
  'liveEngine': 'محرّك التنبؤ الحيّ: نموذج عصبي مُدرَّب',
  'modelAvailableOffline':
      'محرّك التنبؤ الحيّ: محاكاة استدلالية شفافة (النموذج المُدرَّب متاح دون اتصال)',
  'metricsUnavailable': 'تعذّر جلب مقاييس النموذج — تحقّق من اتصال الخادم.',
  'taskPrediction': 'التنبؤ بالنوبة (ما قبل النوبة ضد ما بينها)',
  'taskDetection': 'كشف النوبة (أثناء النوبة ضد غيرها)',
  'perWindow': 'لكل نافذة',
  'colSpecificity': 'النوعية',
  'colThreshold': 'العتبة',
  'modelNotTrained': 'غير مُدرَّب بعد — لا توجد مقاييس لعرضها.',
  'modelBadFormat': 'ملف المقاييس موجود لكن بصيغة غير متوقّعة.',

  'predictionEventsCount': '{n} حدث تنبؤ مُسجَّل',
  'noPredictionEvents':
      'لا توجد أحداث تنبؤ بعد. عند إطلاق تنبيه مبكر — ثم تصعيده أو إلغاؤه خلال '
          'مهلة السماح — يُسجَّل هنا كدليل على أن التنبؤ سبق الحدث.',
  'outcomeEscalated': 'صُعِّد إلى تنبيه',
  'outcomeFalseAlarm': 'أُلغي (إنذار كاذب)',
  'outcomeOnsetConfirmed': 'تأكّد بدء النوبة',
  'outcomePending': 'قيد الانتظار',
  'escalatedShort': 'تصعيد',
  'horizonShort': 'الأفق',

  'deviceIntro':
      'لا يوجد جهاز رأس حقيقي بعد. يمكن التشغيل من قاعدة بيانات إشارات موسومة أو '
          'من محاكاة برمجية، وعند توفّر الجهاز يعمل بالمسار نفسه دون تغيير.',
  'currentSource': 'المصدر الحالي',
  'sourceSimulatorDesc': 'توليد إشارات داخل التطبيق للتجربة السريعة',
  'sourceDatasetDesc':
      'قراءة نوافذ موسومة من قاعدة بيانات الإشارات ثم تحليلها بالنموذج',
  'sourceDeviceDesc': 'بانتظار بيانات الجهاز…',
  'recommendedNow': 'موصى به الآن',
  'serverSettings': 'إعدادات الخادم',
  'demoPathTitle': 'مسار العرض بدون جهاز',
  'demoPathSteps': '١) شغّل الخادم\n'
      '٢) اختر «قاعدة بيانات الإشارات» من هنا\n'
      '٣) راقب الحالة والتنبيه والسجل\n'
      '٤) حساب الأسرة أو الطبيب يرى التنبيهات عبر الخادم',

  // نصوص تُبنى داخل الخدمات حيث لا يوجد BuildContext.
  'notificationFallbackTitle': 'تنبيه',
  'adminUsesWebPanel': 'حساب مدير النظام يُستخدم من لوحة الويب لا من التطبيق.',
  'thePatient': 'المريض',
  'sosMessageSuffix': 'يحتاج مساعدة الآن.',
  'locationIs': 'الموقع: {url}',
  'highRiskNotification': 'ارتفاع في مؤشرات الخطر',
  'preAlertCancelWindowNote':
      'إن كنت بخير فألغِ التنبيه خلال المهلة، وإلا أُبلغت جهات الاتصال تلقائياً.',
  'preAlertNotCancelled': 'لم يُلغَ التنبيه — أُبلغت جهات الاتصال.',
  'withinMinutes': 'خلال {n} دقيقة',

  // biometrics & security
  'biometricPromptReason': 'يرجى التحقق من بصمتك للمتابعة بأمان',
  'autoLockTitle': 'تم قفل التطبيق تلقائياً',
  'autoLockMessage': 'لحماية خصوصية بياناتك الطبية، تم قفل الشاشة بعد 5 دقائق من الخمول.',
  'unlockWithBiometrics': 'فتح القفل بالبصمة',
  'biometricsEnabled': 'تسجيل الدخول بالبصمة',
  'biometricsEnabledDesc': 'استخدام بصمة الإصبع أو الوجه للوصول السريع والآمن',

  // change password
  'changePassword': 'تغيير كلمة المرور',
  'currentPassword': 'كلمة المرور الحالية',
  'newPassword': 'كلمة المرور الجديدة',
  'confirmPassword': 'تأكيد كلمة المرور',
  'passwordChangedSuccess': 'تم تغيير كلمة المرور بنجاح',
  'passwordMismatch': 'كلمتا المرور غير متطابقتين',

  // reports & excel export
  'reportsTitle': 'التقارير الطبية والتحليلات',
  'exportExcel': 'تصدير إلى إكسل (Excel)',
  'exportPdfReport': 'تصدير تقرير طبي (PDF)',
  'filterAll': 'الكل',
  'filterSeizures': 'النوبات',
  'filterAlerts': 'التنبيهات',
  'filterMedications': 'الأدوية',

  // exit dialog & background
  'exitConfirmTitle': 'الخروج من التطبيق',
  'exitConfirmMessage': 'هل ترغب في إغلاق التطبيق أم إبقائه يعمل في الخلفية لمراقبة النوبات؟',
  'keepInBackground': 'إبقاء في الخلفية',
  'exitApp': 'إغلاق التطبيق',

  // clinical messages
  'messagesTitle': 'الرسائل والتوجيهات',
  'typeMessage': 'اكتب رسالة…',
  'repliesDisabledByDoctor': 'الردود معطلة من قبل الطبيب لهذا التوجيه',
  'logoutConfirmBody': 'هل أنت متأكد من رغبتك في تسجيل الخروج من هذا الحساب؟',
  'simulatorTitle': 'محاكي الإشارات الحيوية والتصعيد',
  'openPatientNavigation': 'فتح الملاحة اللحظية (خرائط Google)',
  'patientLocationAvailable': 'الموقع الجغرافي للمريض متاح فوراً',
  'patientLocationAvailableSub': 'اضغط للبدء في الملاحة اللحظية والوصول للمريض عبر خرائط Google',
  'patientDirectPhone': 'هاتف المريض المباشر',
  'preAlertSimulatorStarted': 'تم تفعيل إنذار ما قبل النوبة وبدء عداد الـ 30 ثانية!',
  'preAlertActiveBanner': 'إنذار ما قبل النوبة نشط (Pre-Ictal)',
  'preAlertCountdownSuffix': 'سيتم التصعيد التلقائي للأسرة والطبيب إذا لم يتم الإلغاء',
};

// ---------------------------------------------------------------------------
// English — secondary. A missing key here silently falls back to Arabic, so a
// partial translation degrades to mixed text rather than to a blank label.
// ---------------------------------------------------------------------------
const Map<String, String> _en = {
  'appTitle': 'NeuroShield AI',
  'appSubtitle': 'Unified Clinical Gateway — AI & Early Seizure Forecasting',
  'ok': 'OK',
  'cancel': 'Cancel',
  'save': 'Save',
  'delete': 'Delete',
  'edit': 'Edit',
  'add': 'Add',
  'close': 'Close',
  'retry': 'Retry',
  'back': 'Back',
  'yes': 'Yes',
  'no': 'No',
  'loading': 'Loading…',
  'search': 'Search',
  'all': 'All',
  'none': 'None',
  'unknown': 'Unknown',
  'refresh': 'Refresh',
  'export': 'Export',
  'settings': 'Settings',
  'logout': 'Sign out',
  'requiredField': 'This field is required',
  'optional': 'Optional',
  'notSet': 'Not set',
  'comingSoon': 'Not available yet',
  'minutes': '{n} min',
  'minutesApprox': '~{n} min',
  'minutesUnit': 'min',
  'secondsUnit': 'sec',
  'agoLabel': '{v} ago',
  'justNow': 'just now',

  'errNoConnection': 'No connection. We will retry automatically.',
  'errTimeout': 'The server is slow to respond.',
  'errSessionExpired': 'Your session expired. Please sign in again.',
  'errInvalidCredentials': 'Invalid username or password.',
  'errAccountLocked': 'Account temporarily locked for 15 minutes due to repeated failed attempts.',
  'chatWithPatient': 'Direct Patient Chat',
  'chatWithFamily': 'Family & Caregiver Chat',
  'doctorInboxTitle': 'Clinical Messages & Inbox',
  'searchPatientsAndFamily': 'Search patients & family...',
  'noConversationsFound': 'No matching conversations found',
  'heartRateNormalSinus': 'Normal Sinus Rhythm (Regular) · 60-100 BPM',
  'heartRateElevated': 'Elevated Heart Rate (Tachycardia) · >100 BPM',
  'errForbidden': 'You do not have permission for this action.',
  'errServer': 'A temporary problem on our side — not your data.',
  'errNotFound': 'That item no longer exists.',
  'errValidation': 'Some values are missing or invalid.',
  'errUnknown': 'Something unexpected happened. Please retry.',
  'errTooManyRequests': 'Too many requests. Wait a moment.',
  'errPayloadTooLarge': 'That payload is too large.',

  'emptyTitle': 'Nothing here yet',
  'emptyBody': 'Data will appear as soon as it arrives.',
  'errorTitle': 'Could not complete that',
  'offlineTitle': 'Offline',
  'offlineSince': 'Offline — last update {v}',
  'offlineNoData': 'Offline, and nothing stored locally.',
  'savedLocallyWillSync': 'Saved on this device; it will sync when back online.',
  'pendingSync': 'Pending sync',

  'riskSafeTitle': 'Stable',
  'riskSafeBody': 'No signs of an approaching seizure right now.',
  'riskCautionTitle': 'Slightly elevated',
  'riskCautionBody': 'Stay near a safe place and near someone you know.',
  'riskDangerTitle': 'High likelihood',
  'riskDangerBody': 'Possible seizure in ~{n} min. Sit somewhere safe now.',
  'riskDangerBodyNoLead': 'High seizure likelihood. Sit somewhere safe now.',
  'riskUnknownTitle': 'Not enough data',
  'riskUnknownBody':
      'We cannot assess you right now, and we will not claim you are safe without data.',
  'riskUnknownWhy': 'Reason: the device is offline or no recent reading arrived.',
  'riskStale': 'Last reading is stale',

  'loginTitle': 'Sign in',
  'username': 'Username',
  'password': 'Password',
  'signIn': 'Sign in',
  'signInDemo': 'Demo sign-in',
  'roleLabel': 'Role',
  'rolePatient': 'Patient',
  'roleCaregiver': 'Family member',
  'roleDoctor': 'Doctor',
  'roleAdmin': 'System Administrator',
  'adminHome': 'Admin Control Panel',
  'fullName': 'Full name',

  'patientHome': 'My status',
  'myStatusNow': 'My status now',
  'needHelp': 'I need help',
  'needHelpConfirmTitle': 'Ask for help?',
  'needHelpConfirmBody':
      'Your family and doctor will be alerted immediately, with your location if available.',
  'send': 'Send',
  'sosSent': 'The people who can help you were alerted',
  'sosFailed': 'Could not send — retry or call directly',
  'deviceSection': 'Device',
  'deviceConnected': 'Connected',
  'deviceDisconnected': 'Disconnected',
  'deviceWaiting': 'Waiting for data',
  'battery': 'Battery',
  'signalQuality': 'Signal quality',
  'lastUpdate': 'Last update',
  'nextDose': 'Next dose',
  'takeDose': 'Taken',
  'doseTaken': 'Dose recorded',
  'noDoseDue': 'No dose due soon',
  'last12h': 'Last 12 hours',
  'sourceSection': 'Data source',
  'sourceSimulator': 'Simulator',
  'sourceDataset': 'Dataset',
  'sourceDevice': 'Headband',
  'engineLabel': 'Inference engine',
  'engineDeep': 'Deep learning (CNN-LSTM)',
  'engineSklearn': 'Classical ML (fallback)',
  'engineRules': 'Rule-based (fallback)',
  'bufferedSamples': 'Samples received',
  'manageDevice': 'Manage device',
  'demoHighRisk': 'Simulate high risk',
  'tabHome': 'Home',
  'tabDevice': 'Device',
  'tabAlerts': 'Alerts',
  'tabHistory': 'History',
  'tabMeds': 'Medication',
  'tabEmergency': 'Emergency',

  'activeAlertTitle': 'Active alert',
  'activeAlertHeadline': 'Possible seizure in ~{n} min',
  'activeAlertHeadlineNoLead': 'High seizure likelihood',
  'cancelWindow': 'If you are fine, cancel before the countdown ends',
  'immediateSteps': 'Do this now',
  'step1': 'Sit or lie down somewhere safe.',
  'step2': 'Tell the people around you a seizure may be coming.',
  'step3': 'Move away from stairs, water, and sharp objects.',
  'imOk': 'I am fine',
  'falseAlarm': 'False alarm',
  'notifiedFamily': 'Who was notified',
  'nobodyNotifiedYet': 'Nobody notified yet',
  'imOkRecorded': 'Recorded — no alert will be sent',
  'falseAlarmRecorded': 'Thank you, recorded as a false alarm',
  'falseAlarmWhy':
      'Reporting false alarms is what actually measures this system’s accuracy — it is not a token button.',

  'historyTitle': 'History & analytics',
  'monthlyCalendar': 'Monthly calendar',
  'statsTitle': 'Statistics',
  'seizuresThisMonth': 'Seizures this month',
  'avgLeadTime': 'Average lead time',
  'falseAlarmRate': 'False-alarm rate',
  'eventsTimeline': 'Event timeline',
  'triggersTitle': 'Trigger diary',
  'addTrigger': 'Add trigger',
  'triggerSleep': 'Poor sleep',
  'triggerStress': 'Stress',
  'triggerFatigue': 'Fatigue',
  'triggerMeals': 'Missed meal',
  'triggerMenstrual': 'Menstrual cycle',
  'triggerFever': 'Fever',
  'triggerMissedDose': 'Missed dose',
  'triggerNote': 'Note',
  'triggerIntensity': 'Intensity',
  'correlationTitle': 'Triggers alongside events',
  'correlationDisclaimer':
      'This shows **co-occurrence**, not **cause**. Do not change medication from it; show it to your doctor.',
  'coOccurrence': 'Co-occurred in {n} case(s)',
  'exportPdf': 'Export PDF',
  'exportCsv': 'Export CSV',
  'reportReady': 'Report ready',

  'medsTitle': 'Medication',
  'medName': 'Medication name',
  'dosage': 'Dose',
  'doseTimes': 'Dose times',
  'adherenceWeek': 'Adherence this week',
  'adherenceMonth': 'Adherence this month',
  'refillWarning': '{n} day(s) of medication left',
  'missedDoses': 'Missed doses',
  'shareWithDoctor': 'Share adherence with my doctor',
  'adherenceNote':
      'Poor adherence is among the most common causes of recurring seizures — this screen may help you more than the prediction does.',

  'emergencyTitle': 'Emergency plan',
  'emergencyOfflineNote':
      'This screen works fully offline. When you need it is the worst time to depend on a network.',
  'contactsSection': 'Contacts',
  'addContact': 'Add contact',
  'contactName': 'Name',
  'contactPhone': 'Phone',
  'contactRelation': 'Relation',
  'callNow': 'Call',
  'callFailed': 'Could not place the call — dial manually',
  'priority': 'Priority',
  'medicalCard': 'Medical card',
  'diagnosis': 'Diagnosis',
  'allergies': 'Allergies',
  'bloodType': 'Blood type',
  'treatingDoctor': 'Treating doctor',
  'firstAidTitle': 'First aid during a seizure',
  'firstAid1': 'Stay with them and note the start time.',
  'firstAid2': 'Move hard or sharp objects away.',
  'firstAid3': 'Put something soft under their head.',
  'firstAid4': 'Turn them onto their side to help breathing.',
  'firstAid5': 'Loosen anything tight around the neck.',
  'firstAidDont': 'Do not',
  'firstAidDont1': 'Do not put anything in their mouth.',
  'firstAidDont2': 'Do not hold them down.',
  'firstAidCallAmbulance':
      'Call an ambulance if the seizure lasts over 5 minutes, repeats, consciousness does not return, they are injured, or it is their first seizure.',
  'noContactsYet': 'No contacts',
  'noContactsWarning':
      'Add at least one contact. Without one the app does not know who to call.',

  'settingsTitle': 'Settings',
  'sensitivitySection': 'Alert sensitivity',
  'sensitivityLow': 'Low',
  'sensitivityMedium': 'Medium',
  'sensitivityHigh': 'High',
  'sensitivityTradeoff': 'Higher sensitivity = earlier warning + more false alarms.',
  'sensitivityLowDesc': 'Fewer alerts, higher chance of missing a seizure.',
  'sensitivityMediumDesc': 'A balance between early warning and false alarms.',
  'sensitivityHighDesc': 'Earlier warning, with noticeably more false alarms.',
  'quietHours': 'Quiet hours',
  'quietHoursNote':
      'Non-urgent alerts are muted during these hours. High-risk alerts always override them.',
  'quietFrom': 'From',
  'quietTo': 'To',
  'notifySection': 'Who gets notified',
  'notifyOnCaution': 'Notify family on “slightly elevated”',
  'notifyOnDanger': 'Notify family on “high likelihood”',
  'notifyAlwaysDanger': 'High-risk notification cannot be turned off.',
  'privacySection': 'Privacy',
  'exportMyData': 'Export my data',
  'exportMyDataNote':
      'A copy of your history, medication and events, in a format you can keep.',
  'deleteAccount': 'Delete my account',
  'deleteAccountConfirm':
      'Your account and local data will be deleted. This cannot be undone. Continue?',
  'appearance': 'Appearance',
  'themeSystem': 'Follow system',
  'themeLight': 'Light',
  'themeDark': 'Dark',
  'language': 'Language',
  'languageArabic': 'العربية',
  'languageEnglish': 'English',
  'horizonTitle': 'Prediction horizon (SPH)',
  'horizonNote':
      'How far ahead the system tries to predict. Applies to the offline forecast and the simulator; the server uses PREICTAL_HORIZON_MIN.',
  'reduceMotionNote':
      'This app follows your system “reduce motion” setting and uses no flashing or fast animation.',

  'familyHome': 'Family view',
  'linkedPatients': 'Linked patients',
  'noLinkedPatients': 'No linked patients',
  'noLinkedPatientsBody':
      'The patient must grant you access from their own settings.',
  'currentLocation': 'Current location',
  'locationDisabledByPatient': 'The patient turned location sharing off',
  'respondTitle': 'Respond to alert',
  'sinceAlert': 'Since the alert: {v}',
  'directions': 'Directions',
  'call': 'Call',
  'message': 'Message',
  'onMyWay': 'I am on my way',
  'onMyWayRecorded': 'Others were told you are on your way',
  'respondersSection': 'Family status',
  'seenBy': 'Saw the alert',
  'respondedBy': 'Responded',
  'onWay': 'On the way',
  'noRespondersYet': 'Nobody has responded yet',
  'respondersHint':
      'This stops everyone assuming someone else is going, and stops everyone going at once.',
  'documentSeizure': 'Document the seizure',
  'seizureDuration': 'Duration (seconds)',
  'seizureType': 'Seizure type',
  'seizureTypeFocal': 'Focal',
  'seizureTypeGeneralized': 'Generalized',
  'seizureTypeAbsence': 'Absence',
  'seizureTypeOther': 'Other',
  'seizureNotes': 'Notes',
  'seizureLogged': 'Seizure documented',
  'recentEvents': 'Recent events',

  'consentsTitle': 'Family permissions',
  'consentsIntro':
      'You decide who sees what. You can revoke any permission at any time, with no justification.',
  'consentAlertsOnly': 'Alerts only',
  'consentBasic': 'Basic monitoring',
  'consentFull': 'Full monitoring',
  'consentGuardian': 'Guardian',
  'consentAlertsOnlyDesc': 'Urgent alerts and nothing else.',
  'consentBasicDesc': 'Alerts + your current status and device state.',
  'consentFullDesc': 'The above + history and medication.',
  'consentGuardianDesc': 'Everything + edit rights. For a minor under documented guardianship.',
  'shareLocation': 'Share my location on alert',
  'revoke': 'Revoke',
  'revokeConfirm': 'Revoke this person’s access? They will no longer see your data.',
  'revoked': 'Access revoked',
  'accessLog': 'Access log',
  'accessLogEmpty': 'Nobody has viewed your data yet',
  'consentSaved': 'Permission saved',

  'doctorHome': 'Doctor dashboard',
  'patientsList': 'Patients',
  'sortNeedsAttention': 'Needs attention first',
  'sortByName': 'By name',
  'alerts7d': 'Alerts (7d)',
  'adherenceShort': 'Adherence',
  'filterNewAlerts': 'New alerts',
  'filterBrokenDevices': 'Failing devices',
  'filterLowAdherence': 'Low adherence',
  'searchByName': 'Search by name or record no.',
  'patientFile': 'Patient file',
  'summarySection': 'Summary',
  'timelineSection': 'Timeline',
  'signalWindowSection': 'Signal window',
  'analyticsSection': 'Analytics',
  'clinicalNotes': 'Clinical notes',
  'clinicalNotesHint': 'Private to you; the patient does not see these.',
  'noteSaved': 'Note saved',
  'perPatientSettings': 'Settings for this patient',
  'operatingPoints': 'Operating points',
  'opConservative': 'Conservative',
  'opBalanced': 'Balanced',
  'opSensitive': 'Sensitive',
  'colSensitivity': 'Sensitivity',
  'colFalseAlarmsPerHour': 'False alarms/hour',
  'opImpact': 'This setting means roughly one false alarm every ~{n} hours.',
  'thresholdSaved': 'Sensitivity saved',
  'adjudicationTitle': 'Event adjudication',
  'adjudicationIntro':
      'Your classification of each alert is what measures real-world accuracy, not the test set.',
  'adjTrueSeizure': 'True seizure',
  'adjFalseAlarm': 'False alarm',
  'adjUndetermined': 'Undetermined',
  'adjSaved': 'Adjudication saved',
  'adjPending': 'Awaiting review',
  'adjNoRetrainNote':
      'These reviews are collected and exported only. The model is never retrained automatically from them; any retraining goes through full human review.',
  'reportsSection': 'Reports',
  'modelPerformance': 'Model Performance Metrics (Benchmark Evaluation)',
  'lastVisit': 'Last visit',
  'seizureHistory': 'Seizure history',

  'alertsTitle': 'Alerts',
  'noAlerts': 'No alerts',
  'acknowledge': 'Acknowledge',
  'acknowledged': 'Acknowledged',
  'severityCritical': 'Critical',
  'severityWarning': 'Warning',
  'severityPreAlert': 'Early warning',
  'severityInfo': 'Info',

  'forecastSection': 'Forecast',
  'forecastResearchWarning': 'Unvalidated research score, not a calibrated seizure probability. Seizure onset time cannot be estimated from this score. Do not use it for treatment decisions.',
  'preictalProb': 'Experimental model score',
  'leadTime': 'Lead time',
  'forecastSourceModel': 'Neural forecast model (CNN-LSTM)',
  'forecastSourceHeuristic': 'Simulated forecast',
  'forecastHeuristicWarning':
      'This forecast is simulated for demonstration; it is not the output of a model trained on patient data.',
  'drivers': 'What raised the probability',
  'driverEeg': 'Brain signal',
  'driverHr': 'Heart rate',
  'driverMotion': 'Motion',
  'driverEcg': 'ECG',

  // --- screen-level additions (§3–§5) ---
  'confirm': 'Confirm',
  'saved': 'Saved',
  'deleted': 'Deleted',
  'copied': 'Copied',
  'today': 'Today',
  'yesterday': 'Yesterday',
  'patientLabel': 'Patient',
  'caregiverLabel': 'Family member',
  'noteLabel': 'Note',
  'moveUp': 'Move earlier',
  'moveDown': 'Move later',
  'confirmDelete': 'Delete this item?',
  'quickActions': 'Quick actions',
  'requestQueued': 'Saved — it will be sent once you are online.',

  'appTagline': 'Epilepsy monitoring and early seizure forecasting',
  'showPassword': 'Show password',
  'hidePassword': 'Hide password',
  'demoNote':
      'Real accounts are created from the admin dashboard. Demo mode works without one.',
  'demoUserName': 'Demo user',
  'signInFailed': 'Sign-in failed',

  'noHistoryYet': 'No recorded events yet.',
  'calendarLegendSafe': 'Day with no alerts',
  'calendarLegendCaution': 'Day with a caution alert',
  'calendarLegendDanger': 'Day with a danger alert',
  'prevMonth': 'Previous month',
  'nextMonth': 'Next month',
  'noEventsThisMonth': 'No events this month.',
  'exportFailed': 'Could not create the report.',

  'triggerKind': 'Trigger type',
  'triggerOther': 'Other',
  'triggerLogged': 'Trigger recorded.',
  'triggerHistory': 'Recorded triggers',

  'contactsHint': 'Closest first — one tap to call.',
  'contactSaved': 'Contact saved.',
  'medicalCardSaved': 'Medical card saved.',
  'medicalCardEmpty': 'The medical card is still empty.',
  'doctorPhone': "Doctor's phone",
  'notesLabel': 'Notes',
  'medicalLockScreen': 'Emergency medical screen',
  'lockScreenHint': 'Show this screen to whoever is helping you.',
  'copyMedicalCard': 'Copy card',
  'editMedicalCard': 'Edit card',

  'sensitivitySaved': 'Sensitivity saved.',
  'exportStarted': 'Preparing a copy of your data.',
  'deleteAccountNote':
      'Account deletion is carried out by the administration after your identity is verified; medical records required by law are retained.',

  'openPatient': 'Open patient',
  'respond': 'Respond',
  'noPatientSelected': 'No patient selected.',
  'locationUnavailable': 'Location is not available right now.',
  'arrived': 'Arrived',
  'alertTime': 'Alert time',
  'lastKnownStatus': 'Last known status',

  'addConsent': 'Add permission',
  'noConsentsYet': 'You have not granted any permission yet.',
  'consentLevelLabel': 'Permission level',

  'attentionNeeded': 'Needs attention',
  'noPatientsYet': 'No patients are linked to your account.',
  'operatingPointNote':
      'The operating point is a trade-off: higher sensitivity detects more, and raises more false alarms.',
  'applyThreshold': 'Apply',
  'noAdjudicationsPending': 'No alerts awaiting adjudication.',
  'verdictLabel': 'Verdict',
  'openFile': 'Open file',

  'alertNotFound': 'This alert has ended or is no longer available.',

  'medReminderTitle': 'Medication reminder',
  'medReminderBody': 'Time for {name} at {time}.',
  'scheduleDaily': 'Daily',

  'weekdayInitials': 'Sun,Mon,Tue,Wed,Thu,Fri,Sat',
  'monthNames':
      'January,February,March,April,May,June,July,August,September,October,November,December',
  'chartNoData': 'No signal data yet.',
  'totalAlerts': 'Total alerts',

  'accessViewedStatus': 'viewed your status',
  'accessViewedHistory': 'viewed your history',
  'accessViewedMeds': 'viewed your medications',
  'accessConsentChanged': 'permission changed',
  'accessConsentRevoked': 'permission revoked',
  'accessAlertResponse': 'responded to an alert',
  'accessExported': 'exported a copy of the data',

  'noMedsYet': 'No medications recorded yet.',
  'addMedication': 'Add medication',
  'pauseMed': 'Pause',
  'resumeMed': 'Resume',
  'medPaused': 'Paused',
  'takenAt': 'Taken',
  'dueAt': 'Due',
  'todayPlan': "Today's plan",

  'liveEngine': 'Live forecast engine: trained neural model',
  'modelAvailableOffline':
      'Live forecast engine: transparent heuristic (trained model available offline)',
  'metricsUnavailable': 'Could not load model metrics — check the server connection.',
  'taskPrediction': 'Seizure prediction (preictal vs interictal)',
  'taskDetection': 'Seizure detection (ictal vs non-ictal)',
  'perWindow': 'per window',
  'colSpecificity': 'Specificity',
  'colThreshold': 'Threshold',
  'modelNotTrained': 'Not trained yet — no metrics to show.',
  'modelBadFormat': 'The metrics file exists but is in an unexpected format.',

  'predictionEventsCount': '{n} prediction events recorded',
  'noPredictionEvents':
      'No prediction events yet. When a pre-alert fires — and is then escalated '
          'or cancelled within the grace window — it is logged here as evidence '
          'that the forecast preceded the event.',
  'outcomeEscalated': 'Escalated to an alert',
  'outcomeFalseAlarm': 'Cancelled (false alarm)',
  'outcomeOnsetConfirmed': 'Seizure onset confirmed',
  'outcomePending': 'Pending',
  'escalatedShort': 'Escalated',
  'horizonShort': 'Horizon',

  'deviceIntro':
      'There is no real head device yet. You can run from a labelled signal '
          'dataset or from a software simulator; when the device arrives it uses '
          'the same path unchanged.',
  'currentSource': 'Current source',
  'sourceSimulatorDesc': 'Signals generated inside the app for a quick trial',
  'sourceDatasetDesc':
      'Reads labelled windows from the signal dataset and analyses them with the model',
  'sourceDeviceDesc': 'Waiting for device data…',
  'recommendedNow': 'recommended now',
  'serverSettings': 'Server settings',
  'demoPathTitle': 'Demo path without a device',
  'demoPathSteps': '1) Start the server\n'
      '2) Choose "Signal dataset" here\n'
      '3) Watch the status, the alert, and the history\n'
      '4) The family or doctor account sees alerts through the server',

  'notificationFallbackTitle': 'Alert',
  'adminUsesWebPanel':
      'The system administrator account is used from the web panel, not the app.',
  'thePatient': 'The patient',
  'sosMessageSuffix': 'needs help now.',
  'locationIs': 'Location: {url}',
  'highRiskNotification': 'Risk indicators are rising',
  'preAlertCancelWindowNote':
      'If you are fine, cancel the alert within the grace window; otherwise your '
          'contacts are notified automatically.',
  'preAlertNotCancelled': 'The alert was not cancelled — contacts were notified.',
  'withinMinutes': 'within {n} minutes',

  // biometrics & security
  'biometricPromptReason': 'Please verify your biometrics to proceed securely',
  'autoLockTitle': 'App Auto-Locked',
  'autoLockMessage': 'To protect your medical privacy, the app locked after 5 minutes of inactivity.',
  'unlockWithBiometrics': 'Unlock with Biometrics',
  'biometricsEnabled': 'Biometric Login',
  'biometricsEnabledDesc': 'Use fingerprint or face recognition for fast and secure access',

  // change password
  'changePassword': 'Change Password',
  'currentPassword': 'Current Password',
  'newPassword': 'New Password',
  'confirmPassword': 'Confirm Password',
  'passwordChangedSuccess': 'Password changed successfully',
  'passwordMismatch': 'Passwords do not match',

  // reports & excel export
  'reportsTitle': 'Medical Reports & Analytics',
  'exportExcel': 'Export to Excel (.xlsx)',
  'exportPdfReport': 'Export Medical Report (PDF)',
  'filterAll': 'All',
  'filterSeizures': 'Seizures',
  'filterAlerts': 'Alerts',
  'filterMedications': 'Medications',

  // exit dialog & background
  'exitConfirmTitle': 'Exit Application',
  'exitConfirmMessage': 'Do you want to close the app or keep it running in the background for seizure monitoring?',
  'keepInBackground': 'Keep in Background',
  'exitApp': 'Exit App',

  // clinical messages
  'messagesTitle': 'Messages & Directives',
  'typeMessage': 'Type a message…',
  'repliesDisabledByDoctor': 'Replies are disabled by the doctor for this directive',
  'logoutConfirmBody': 'Are you sure you want to log out of this account?',
  'simulatorTitle': 'Vital Signs Simulator & Escalation',
  'openPatientNavigation': 'Open Live Navigation (Google Maps)',
  'patientLocationAvailable': 'Patient GPS Location Available',
  'patientLocationAvailableSub': 'Tap to start live turn-by-turn navigation via Google Maps',
  'patientDirectPhone': 'Direct Patient Phone',
  'preAlertSimulatorStarted': 'Pre-Ictal forecast triggered and 30s countdown started!',
  'preAlertActiveBanner': 'Pre-Ictal Forecast Active',
  'preAlertCountdownSuffix': 'Will automatically escalate to family & doctor if not cancelled',
};

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.supportedLocales.any(
        (l) => l.languageCode == locale.languageCode,
      );

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
