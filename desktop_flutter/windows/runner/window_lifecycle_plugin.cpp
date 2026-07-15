#include "window_lifecycle_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>

namespace {

class TransVortexWindowLifecyclePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar) {
    auto plugin =
        std::make_unique<TransVortexWindowLifecyclePlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit TransVortexWindowLifecyclePlugin(
      flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        channel_(
            std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                registrar->messenger(), "transvortex/window_lifecycle",
                &flutter::StandardMethodCodec::GetInstance())) {
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return HandleWindowProc(hwnd, message, wparam, lparam);
        });
  }

  ~TransVortexWindowLifecyclePlugin() override {
    if (window_proc_id_ >= 0) {
      registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
    }
  }

 private:
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
    if (message == WM_CLOSE) {
      channel_->InvokeMethod("onClose", nullptr);
    }
    return std::nullopt;
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int window_proc_id_ = -1;
};

}  // namespace

void RegisterTransVortexWindowLifecyclePlugin(
    FlutterDesktopPluginRegistrarRef registrar) {
  TransVortexWindowLifecyclePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
