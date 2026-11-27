# Offline-First Hybrid Architecture & Resilience Guide

This guide establishes the engineering protocols for local-to-cloud parity, edge inference fallback, offline GNSS/SMS emergency handling, and Android permissions management.

---

## 1. Edge-Cloud Dual Model Execution (Zero-Lag Offline Parity)

### Problem & Invariant
* Cloud model (`CloudPreictalNet`, 417 KB ONNX) offers high-precision preictal seizure forecasting (10–15 min horizon) over WebSocket/HTTPS.
* Offline heuristic currently falls back to basic peak/zero-crossing analysis in Dart.
* **Invariant:** Patients must not lose predictive AI capability merely because mobile connectivity drops.

### Architecture Protocol
1. **Model Packaging:**
   * Package both `cloud_preictal_model.onnx` and `edge_seizure_model.onnx` as assets in the client application.
   * Total model size is under 700 KB, easily fitting within mobile memory and cold-start constraints.
2. **Unified Online/Offline Orchestration State Machine (Patient Account):**
   * Provide a single authoritative connectivity & failover orchestrator coordinating all patient services:
   * When `apiOnline == true` (**Online Mode**):
     - Activate cloud DB sync, virtual hardware/simulator streaming, cloud high-accuracy seizure prediction (`/analyze`), cloud alerts/SOS dispatch, caregiver reachability/online presence & alert-receipt verification, accurate GPS geolocation, and real-time messaging/clinical updates.
     - Keep mobile CPU cool and sync state seamless without exposing raw cloud wake-up messages ("جاري إيقاظ الخادم السحابي").
   * When `apiOnline == false` (**Full Local Offline Mode**):
     - Surface a clear, simple, non-technical indicator showing the user is in **Local Offline Mode** (`وضع محلي — دون اتصال بالإنترنت`).
     - Immediately switch **every service** to local execution with zero data loss:
       1. Local simulator telemetry continues uninterrupted.
       2. `EdgeModelService` performs **active local seizure prediction** matching the cloud model's output contract (`preictal_prob`, `lead_time_min`, `predicted`, severity escalation) across all valid patient sessions.
       3. All readings, medication logs, messages, and prediction events persist atomically in SQLCipher + durable outbox (`serverOrigin`-scoped).
       4. Offline emergency alerts trigger local alarms + **native SMS SOS fallback** with direct satellite GNSS coordinates (`Geolocator`, `forceLocationManager: true` on Android).
   * When `apiOnline` returns:
     - Reconcile outbox queue atomically in chronological order with idempotency keys, then hand inference back to the cloud cleanly without dropping in-flight packets.

---

## 2. Location & Emergency Communications (GNSS & Cellular Fallback)

### Problem & Invariant
* When data connection is lost, cloud push (FCM) cannot reach caregivers.
* **Invariant:** The device must capture authentic GNSS coordinates without internet and deliver emergency alerts via alternative physical channels without making false claims of direct satellite data links.

### Operational Protocol
1. **Autonomous GNSS Capture:**
   * Smartphone GNSS receivers (GPS, Galileo, GLONASS) calculate positioning directly from satellite radio frequency broadcasts, requiring zero cellular or internet data.
   * `LocationService` captures fix with `latitude`, `longitude`, `accuracy` (in meters), and UTC timestamp.
   * Reject coordinates if `accuracy > 100m` or fix is stale (> 5 minutes old), displaying clear warning instead of fabricating coordinates.
2. **Emergency Fallback (SMS Payload):**
   * If an emergency or high-risk seizure is detected while offline:
     - Format a structured SMS payload:
       `[طارئ طبي]: نوبة صرع محتملة للمريض [الاسم]. الموقع: https://maps.google.com/?q={lat},{lon} (دقة {acc}م في {time})`
     - Trigger native SMS dispatcher to registered caregiver emergency numbers.
     - Log attempt in local outbox with recipient and timestamp.
3. **Satellite Direct-to-Cell (NTN) Clarification:**
   * Standard smartphones do not possess satellite radio transmitters.
   * Do not represent cellular SMS as satellite messaging unless running on dedicated NTN-capable hardware (e.g., Bullitt, Snapdragon Satellite, or Garmin InReach accessory).

---

## 3. Network Resilience & Synchronization Boundary

### Protocols
1. **Network Flap Protection:**
   * Distinguish between Wi-Fi connection and actual internet connectivity (probe `/health` with bounded timeout).
   * Apply exponential backoff with jitter (1s, 2s, 4s, 8s, up to 30s) on failed sync attempts.
2. **Zero Data Loss Outbox:**
   * Care records, medication adherence, and seizure logs are committed to SQLite in the same database transaction as their outbox intent.
   * Re-synchronization must use idempotent IDs (`requestId`); server must deduplicate requests without creating redundant entries.
3. **Conflict Resolution:**
   * Multi-device edits trigger explicit conflict resolution (`resolveCardConflict`), preserving local drafts and prompting the user rather than silently overwriting.

---

## 4. Android Permissions Lifecycle & In-App Diagnostics

### Operational Rules
1. **Required Permissions:**
   * `POST_NOTIFICATIONS` (Android 13+): Emergency waking & seizure pre-alerts.
   * `ACCESS_FINE_LOCATION`: Emergency SOS coordinates.
   * `BLUETOOTH_SCAN` & `BLUETOOTH_CONNECT`: Sensor headset pairing.
   * `BODY_SENSORS`: Real-time physiological signal ingestion.
   * `USE_BIOMETRIC`: Patient health record privacy & idle lock.
2. **In-App Management:**
   * In addition to the first-launch onboarding screen (`PermissionsOnboardingScreen`), provide a dedicated settings page allowing patients to view permission status at any time.
   * When a critical permission is revoked, present an inline banner with a direct deep-link to Android App Settings (`openAppSettings()`).
