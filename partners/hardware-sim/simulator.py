import random
import math


def generate_sensor_data():
    # محاكاة نبض القلب
    heart_rate = random.randint(65, 100)

    # محاكاة الحركة
    x = random.uniform(-1.5, 1.5)
    y = random.uniform(-1.5, 1.5)
    z = random.uniform(-1.5, 1.5)

    acceleration = math.sqrt(x**2 + y**2 + z**2)

    return {
        "heart_rate": heart_rate,
        "x": round(x, 2),
        "y": round(y, 2),
        "z": round(z, 2),
        "acceleration": round(acceleration, 2)
    }