#include "include/firebase_core/firebase_core_plugin_c_api.h"

extern "C" {

void FirebaseCorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  // No-op stub for Windows desktop where Firebase is not initialized or used.
  // FCM push notifications are Android-only; Windows communicates via backend polling.
  (void)registrar;
}

}
