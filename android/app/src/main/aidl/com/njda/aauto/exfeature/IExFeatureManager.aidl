package com.njda.aauto.exfeature;

import android.view.Surface;
import com.njda.aauto.exfeature.IExMediaBrowser;
import com.njda.aauto.exfeature.IExRouteGuidance;

// Declaration order is the wire. AIDL numbers transactions from 1 in the
// order written here, and these eight match the OEM stub's `onTransact`
// switch exactly (AndroidAuto/sources/w1/a.java, cases 1-8). Do not reorder,
// and do not remove a method this app never calls: dropping one would shift
// every transaction after it onto the wrong remote method.
//
// The two listener interfaces are declared empty on purpose. Their own methods
// are irrelevant here — this app never registers a listener (this app never registers a listener) — but the parameter types must exist for the
// slots to be numbered correctly.
interface IExFeatureManager {
    void registerMediaBrowserListener(IExMediaBrowser listener);
    void registerRouteGuidanceListener(IExRouteGuidance listener);

    void notifyMainSurfaceAttached(in Surface surface, int width, int height);
    void notifyMainSurfaceDetached();
    void notifyClusterSurfaceAttached(in Surface surface, int width, int height);
    void notifyClusterSurfaceDetached();
    void notifyAuxiliarySurfaceAttached(in Surface surface, int width, int height);
    void notifyAuxiliarySurfaceDetached();
}
