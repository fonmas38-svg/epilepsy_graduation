# EEG evidence, local/cloud parity and device simulation

This module is original project guidance. The research did not establish a ready-made skill that validates clinical EEG seizure prediction. Generic Hugging Face LLM evaluations are not a replacement.

Trace the actual notebook/training pipeline, dataset provenance/license, cohort, labels, weights/checksums, preprocessing, normalization, channel order, sampling frequency, window/hop and output meaning. Inspect artifacts rather than assuming a bundled file is active. Separate interictal/ictal classification (detection) from preictal forecasting (prediction). Synthetic high-risk inputs and manual phase forcing do not prove anticipation of a real seizure.

Evaluate held-out patients/recordings without overlapping-window or preprocessing leakage. Freeze the threshold before final testing. For prediction report event sensitivity, false alarms per monitored hour, time in warning, prediction horizon/occurrence period and usable monitoring duration; for classification report per-class results/calibration and uncertainty. Report exclusions and inadequate sample size. If continuous EEG with seizure onset annotations is unavailable, explicitly state prediction performance cannot be established. Do not promise a target accuracy, coverage of all seizure types or readiness for patient use.

Compare local/cloud weights, preprocessing and runtime operators using identical fixed inputs and declared numeric tolerances. Check invalid signals, missing channels, NaN/Inf, clipping, disconnection, drift and inference latency/memory. A heuristic fallback must be labelled separately; matching input shape is not model equivalence.

Treat the declared /device/contract and actual hardware requirements as evidence to reconcile, not assumed truth. Verify units, calibration, electrode/reference/channel mapping, sequence numbers, monotonic acquisition time, packet boundaries, buffering, reconnect/replay, duplication, source ownership and device-to-patient enrollment. Do not claim compatibility with unspecified hardware. Fix the duplicate `@router.get('/contract')` route declaration in `backend/app/routers/device.py`.

## Unified Hardware Abstraction (`IEegHardwareDevice`)

- Decouple `MonitoringService`, `EdgeModelService`, and UI waveform painters from raw `SignalSimulator` timers or hardcoded HTTP polling by introducing a single polymorphic interface:
  - `Stream<EegPacket> get packetStream;`
  - `Stream<DeviceConnectionState> get connectionStateStream;`
  - `Future<void> connect();`
  - `Future<void> disconnect();`
  - `Future<DeviceDiagnostics> getDiagnostics();`
- Concrete implementations:
  1. `SoftwareEmulatorEegDevice`: Streams from the Render/local simulator (existing HTTP `POST /device/ingest`, `GET /device/status/{patient_id}`, `POST /simulate/stream`, or planned Phase 3 WebSocket `/device/stream/ws`) or deterministic synthetic rhythms with artifact injection.
  2. `BleEegHardwareDevice`: Uses BLE GATT subscriptions (e.g., `flutter_reactive_ble`, verifying `pubspec.yaml` compatibility before adding) for wireless headbands.
  3. `UsbSerialEegHardwareDevice`: Uses COM/USB serial (`usb_serial`) for wired Windows/Android hardware.
- Run high-rate (e.g., 256Hz) ingestion and ring-buffering off the UI isolate so cold-start latency or CPU throttling does not drop packets or freeze rendering.

## Doctor Event Review (`AdjudicationScreen`) Clinical Contract

- Event review must display actionable clinical evidence, not only patient name and severity text:
  - 12-hour event timestamp, episode duration, AI detection confidence, and 10s pre/post-ictal 4-channel EEG waveform (`SignalChart` with zoom/pan).
  - Synchronized heart-rate and accelerometer motion telemetry.
  - Structured clinical classification (e.g., Generalized Tonic-Clonic, Focal with Impaired Awareness, Absence, Atonic, Non-epileptic Artifact) plus artifact root-cause tags (muscle activity, electrode impedance drop, head motion).
- Enforce `CONSTRAINT uq_outcomes_alert UNIQUE(patient_id, alert_id)` and an optimistic concurrency `version` column on `outcomes` (`WHERE version = :expected`) so concurrent mobile/web reviews cannot silently overwrite each other.

## Unified Clinical Signal Engine & Live Oscilloscope (Latest Updates)

- **Default Signal Source to Dataset**: Unified `monitoring.source = SignalSource.dataset` as the system default. The application feeds real recorded clinical EEG windows (CHB-MIT) into the CNN-LSTM deep learning model on `/dataset/next`, producing authentic prediction probabilities, lead times, and risk assessments.
- **Seamless Local Fallback**: When offline or if the cloud server is unreachable, `SoftwareEmulatorEegDevice` automatically falls back to local `SignalSimulator` rhythms to ensure continuous, zero-freeze telemetry without disrupting patient monitoring.
- **Live Moving Oscilloscope Visualizer**: Replaced static window redraws with `_LiveOscilloscopeWave` and `_OscilloscopeWavePainter` running at 60 FPS. Features clinical dark monitor styling (`#0D1520`), 16px grid lines, continuous cyclical waveform advancement, channel headers (`ECG LEAD II`, `EEG FP1-F3`, `ACCELEROMETER`), a live pulsating `256Hz` badge, and a glowing oscilloscope scan beam. Sweep speed dynamically scales with heart rate to visually depict tachycardia during seizures.
- **4-Phase Clinical Seizure Stepper**: `PatientSimulatorScreen` features an interactive visual pipeline stepper:
  1. *Interictal*: Calm baseline rhythm.
  2. *Pre-Ictal*: AI forecast prediction, lead-time countdown banner, and patient cancel button.
  3. *Ictal*: Active seizure spikes, critical emergency alert, automatic GPS location dispatch to family.
  4. *Post-Ictal*: Calming recovery phase.
- **UI Streamlining**: Removed confusing `[محاكي / بيانات / جهاز]` choice chips from the patient screen in favor of an elegant `_MonitoringEngineCard` with a 1-tap `[ ⚡ تجربة رصد نوبة مبكرة ]` demo button.

Simulator scenarios: baseline, gradual synthetic transition, ictal-like pattern, recovery, noise/mains, flatline, clipping, missing packets, reordered/duplicated packets and restart. Use deterministic seeds and acquisition-time scheduling independent of packet size. Distinguish test waveform from model decision, and test missed-prediction recording against an independent onset annotation. Simulation must not send real emergency messages or mix with clinical records without explicit authorized test routing.

Before proposing real-patient testing, report missing external validation, hardware and clinical supervision requirements; engineering tests alone do not provide clinical authorization.
