"""Complete fictional onboarding data for tests that are not testing missing fields."""
import hashlib


def doctor_payload(payload):
    tag = hashlib.sha256(str(payload.get("username", "test")).encode()).hexdigest()[:16]
    return {"phone": "+967700000001", "license_number": "TEST-" + tag,
            "national_id": "TEST-" + tag, "specialization": "Neurology",
            "hospital_affiliation": "Test hospital", "moh_override": True, **payload}


def patient_payload(payload):
    return {"age": 30, "gender": "female", "phone": "+967700000002",
            "emergency_contact": "+967700000003", "diagnosis": "Test diagnosis", **payload}
