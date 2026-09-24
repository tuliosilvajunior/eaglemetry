package com.njda.carplay.exfeature;

import android.view.Surface;
import com.njda.carplay.exfeature.IExAppList;
import com.njda.carplay.exfeature.IExCallUpdate;
import com.njda.carplay.exfeature.IExEnhanceSiri;
import com.njda.carplay.exfeature.IExMediaBrowser;
import com.njda.carplay.exfeature.IExRouteGuidance;

interface IExFeatureManager {
    void registerCallUpdateListener(IExCallUpdate listener);
    void registerMediaBrowserListener(IExMediaBrowser listener);
    void registerRouteGuidanceListener(IExRouteGuidance listener);
    void registerEnhancedSiriListener(IExEnhanceSiri listener);
    void registerAppListListener(IExAppList listener);

    void notifySwapCall();
    void notifyMergeCall();
    void notifyMuteUpdate(boolean muted);
    void notifyInitiateCall(String id);
    void notifyEndCall(String id, boolean held);
    void notifyAcceptCall(String id, boolean held);
    void notifyHoldUpdate(String id, boolean held);
    void notifyEnhancedSiriVoiceWakeup(long wakeupTime);
    void notifyAppIconRequest(String appId);
    void notifyAppLaunch(String appId);

    void notifyMainSurfaceAttached(in Surface surface, int width, int height);
    void notifyMainSurfaceDetached();
    void notifyClusterSurfaceAttached(in Surface surface, int width, int height);
    void notifyClusterSurfaceDetached();
    void notifyAuxiliarySurfaceAttached(in Surface surface, int width, int height);
    void notifyAuxiliarySurfaceDetached();
    void notifySystemInfo(String systemVersion, String vehicleName, String oemIconLabel, String oemIconPath);
    void notifyUiConfigChanged(int config);
    void updateViewArea(int displayType, int offsetX, int offsetY, int width, int height);
}
