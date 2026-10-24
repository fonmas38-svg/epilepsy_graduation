"""
اختبارات وحدة للتحقق من صحة محاكي جهاز الرأس (Device Simulator Unit Tests)
"""
import math
import pytest
from sim_client import DeviceSimulator


def test_generator_bounds_and_finite():
    """اختبار أن جميع القيم المولدة تقع ضمن النطاق المسموح وتخلو من NaN و Infinity."""
    sim = DeviceSimulator()

    for pattern in ("stable", "watch", "high_risk", "ramp"):
        for progress in (0.0, 0.5, 1.0):
            samples = sim.generate_samples(pattern=pattern, progress=progress, n=32)
            assert len(samples) == 32

            for s in samples:
                # النبض يجب أن ينحصر بين 20 و 240
                assert 20.0 <= s["hr"] <= 240.0, f"قيمة Nبض خارج المدى: {s['hr']}"

                # القنوات الحيوية يجب أن تكون أعداداً حقيقية منتهية
                for channel in ("eeg", "ecg", "motion", "hr"):
                    assert math.isfinite(s[channel]), f"قيمة غير منتهية في القناة {channel}: {s[channel]}"


def test_sequence_number_increment():
    """اختبار الترقيم التسلسلي لمنع تكرار الدفعات."""
    sim = DeviceSimulator()
    assert sim.sequence_number == 0


def test_invalid_pattern_raises():
    """اختبار التعامل مع الأنماط غير المعرفة."""
    sim = DeviceSimulator()
    with pytest.raises(ValueError):
        sim.generate_samples(pattern="invalid_pattern")


def test_waveform_is_independent_of_packet_size():
    full = DeviceSimulator(seed=42).generate_samples("stable", n=256)
    chunked = DeviceSimulator(seed=42)
    split = sum((chunked.generate_samples("stable", n=32) for _ in range(8)), [])
    assert full == split


@pytest.mark.parametrize("pattern", ["flatline", "mains_noise", "clipping"])
def test_fault_profiles_are_reproducible(pattern):
    assert DeviceSimulator(seed=1).generate_samples(pattern) == DeviceSimulator(seed=1).generate_samples(pattern)


@pytest.mark.parametrize("size", [0, -1, 513])
def test_invalid_packet_sizes_rejected(size):
    with pytest.raises(ValueError):
        DeviceSimulator().generate_samples("stable", n=size)


def test_enrollment_includes_patient_binding(monkeypatch):
    import httpx
    sent = []
    def post(url, **kwargs):
        sent.append(kwargs["json"])
        return httpx.Response(200, json={"access_token": "valid"})
    monkeypatch.setattr(httpx, "post", post)
    simulator = DeviceSimulator(patient_id="p1")
    assert simulator.fetch_token() == "valid"
    assert sent[0]["patient_id"] == "p1"


def test_failed_batch_does_not_advance_sequence():
    import httpx
    simulator = DeviceSimulator()
    simulator.access_token = "valid"
    with httpx.Client(transport=httpx.MockTransport(
            lambda request: httpx.Response(500, request=request))) as client:
        with pytest.raises(httpx.HTTPStatusError):
            simulator.send_batch(simulator.generate_samples("stable"), client)
    assert simulator.sequence_number == 0
