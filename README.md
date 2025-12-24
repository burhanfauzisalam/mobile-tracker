# mobile_tracker

Flutter application that streams GPS data over MQTT (including device id, user id, battery, and epoch timestamp).  
The tracker now relies on a background service so data keeps flowing every 15 seconds even when the UI is minimized on Android.

## Running the tracker

1. Install dependencies:
   ```bash
   flutter pub get
   ```
2. Enable developer options on the Android device/emulator and ensure GPS is turned on.
3. Run the app on a physical device (`flutter run`). The Chrome/web target is not supported for background tracking.

.
## Android/iOS notes

- Android manifests include `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE`, and `POST_NOTIFICATIONS`. On Android 13+ the user must also approve the runtime notification permission for the service notification to appear.
- iOS builds need Background Modes → *Location updates* plus the relevant Info.plist strings (`NSLocationAlwaysAndWhenInUseUsageDescription`, etc.). The app currently focuses on Android; adding the iOS background entitlement is required before distributing there.
- The service is disabled on Flutter Web/Chrome.

## Building an APK

```bash
flutter build apk --release
```

The output is placed in `build/app/outputs/flutter-apk/app-release.apk`. Sign with your own keystore before publishing.
