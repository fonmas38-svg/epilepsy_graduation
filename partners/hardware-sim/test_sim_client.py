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
