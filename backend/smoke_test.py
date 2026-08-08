import json
import urllib.request

base = "http://127.0.0.1:8000"


def post(path, payload):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


health = json.load(urllib.request.urlopen(base + "/health"))
print("health", health)

sim = post("/simulate/stream", {"pattern": "high_risk", "samples": 64, "seed": 1})
print("sim", sim["pattern"], len(sim["window"]["eeg"]))

result = post("/analyze", sim["window"])
print("analyze", result["label"], round(result["confidence"], 3), result["processing_ms"])

alert = post("/alerts/evaluate", {"patient_id": "p1", "window": sim["window"]})
print("alert", alert["should_notify"], alert["severity"])
