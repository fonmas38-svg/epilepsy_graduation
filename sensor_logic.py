def detect_fall(acceleration):
    if acceleration > 5:
        return True
    return False


def analyze_heart_rate(heart_rate):
    if heart_rate > 120:
        return "HIGH"
    elif heart_rate < 50:
        return "LOW"
    else:
        return "NORMAL"