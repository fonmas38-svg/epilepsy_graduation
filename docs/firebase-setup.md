# Firebase setup notes (V1)

## Enabled services
- Authentication (Email/Password)
- Cloud Firestore
- Cloud Messaging (FCM)

## Deploy rules
```bash
firebase deploy --only firestore:rules
```
Rules file: `docs/firestore.rules`

## Mobile wiring
1. Run `flutterfire configure` in `mobile/`
2. Replace demo auth in `lib/services/auth_service.dart` (search TODO(firebase))
3. Replace cloud mirrors in `lib/services/sync_service.dart`
4. Launch with:
```bash
flutter run --dart-define=DEMO_MODE=false
```

## FCM path
1. App stores `fcmToken` on user profile
2. Backend `/alerts/evaluate` marks `should_notify`
3. Production: replace `/alerts/fcm-stub` with Firebase Admin `messaging.send`
4. Foreground handling: `NotificationService` in the Flutter app
