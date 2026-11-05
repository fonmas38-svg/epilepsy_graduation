"""Configuration checks do not replace SMS/GNSS tests on physical handsets."""
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2] / 'mobile'


def test_android_allows_querying_user_confirmed_sms_without_direct_send_permission():
    manifest = ET.parse(ROOT / 'android/app/src/main/AndroidManifest.xml').getroot()
    namespace = '{http://schemas.android.com/apk/res/android}'
    schemes = {e.get(namespace + 'scheme') for e in manifest.findall('./queries/intent/data')}
    assert {'sms', 'tel'} <= schemes
    permissions = {e.get(namespace + 'name') for e in manifest.findall('./uses-permission')}
    assert 'android.permission.ACCESS_FINE_LOCATION' in permissions
    assert 'android.permission.SEND_SMS' not in permissions


def test_ios_sms_visibility_and_location_reason_are_declared():
    with (ROOT / 'ios/Runner/Info.plist').open('rb') as source:
        config = plistlib.load(source)
    assert {'sms', 'tel'} <= set(config['LSApplicationQueriesSchemes'])
    assert config['NSLocationWhenInUseUsageDescription']
