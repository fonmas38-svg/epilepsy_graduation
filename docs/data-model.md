# Data Model

## User
| Field | Type | Notes |
|-------|------|-------|
| uid | string | Firebase Auth uid |
| name | string | |
| role | string | `patient` \| `caregiver` \| `doctor` |
| phone | string | optional |
| email | string | |
| linkedPatientIds | string[] | for caregiver/doctor |
| fcmToken | string | optional |

## PatientProfile
| Field | Type | Notes |
|-------|------|-------|
| patientId | string | equals user uid for patient role |
| diagnosis | string | |
| medications | string[] | |
| caregivers | string[] | uids |
| doctors | string[] | uids |
| currentStatus | string | last risk label |
| lastUpdated | timestamp | |

## VitalReading
| Field | Type | Notes |
|-------|------|-------|
| id | string | |
| patientId | string | |
| timestamp | timestamp | |
| eeg | number[] | |
| ecg | number[] | |
| motion | number[] | |
| hr | number | |
| synced | bool | local SQLite flag |

## RiskAssessment
| Field | Type | Notes |
|-------|------|-------|
| id | string | |
| patientId | string | |
| timestamp | timestamp | |
| label | string | stable/watch/high_risk |
| confidence | number | |
| features | map | feature vector |
| processingMs | number | |

## Alert
| Field | Type | Notes |
|-------|------|-------|
| id | string | |
| patientId | string | |
| timestamp | timestamp | |
| severity | string | info/warning/critical |
| message | string | |
| recipients | string[] | roles or uids |
| acknowledged | bool | |
| acknowledgedBy | string | optional |
