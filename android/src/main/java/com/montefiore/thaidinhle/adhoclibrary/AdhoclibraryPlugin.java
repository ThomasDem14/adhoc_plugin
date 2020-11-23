package com.montefiore.thaidinhle.adhoclibrary;

import android.util.Log;
import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

public class AdhoclibraryPlugin implements FlutterPlugin, MethodCallHandler {
  private static final String TAG = "[Adhoc.Plugin][Plugin]";
  private static final String CHANNEL = "ad.hoc.lib/blue.manager.channel";

  private MethodChannel mChannel;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    Log.d(TAG, "onAttachedToEngine");

    mChannel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    mChannel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "startAdvertise":
        
        break;

      case "stopAdvertise":

        break;
    
      default:
        result.notImplemented();
        break;
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    mChannel.setMethodCallHandler(null);
  }
}
