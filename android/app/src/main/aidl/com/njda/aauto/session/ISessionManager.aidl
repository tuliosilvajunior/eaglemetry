package com.njda.aauto.session;

import android.view.MotionEvent;
import com.njda.aauto.session.ISessionListener;

// The declaration order IS the wire — see the note in the CarPlay twin of this
// file. Copied 1:1 from the TRANSACTION_* constants of the unobfuscated stub in
// ConnAdaptor.apk
// (out/jadx/ConnAdaptor/sources/com/njda/aauto/session/ISessionManager.java:153-173).
interface ISessionManager {
    void registerSessionListener(ISessionListener listener);       // tx 1
    boolean isDemoMode();                                          // tx 2
    boolean isProductActivate();                                   // tx 3
    boolean isForeground();                                        // tx 4
    void requestForeground(String reason);                         // tx 5
    void notifyGoBackground();                                     // tx 6
    void notifyAudioFocusChange(int type, int state);              // tx 7
    void sourceToAndroidAuto();                                    // tx 8
    void notifyLocalVoice(int state);                              // tx 9
    void notifyLocalNavigation(boolean active);                    // tx 10
    void notifyMediaMute(boolean mute);                            // tx 11
    void notifyGlobalMute(boolean mute);                           // tx 12
    void notifyStartMedia(boolean press);                          // tx 13
    void notifyStopMedia(boolean press);                           // tx 14
    void notifyFlashMedia(boolean press);                          // tx 15
    void notifyVoiceKey(boolean press);                            // tx 16
    void notifyNextTrack(boolean press);                           // tx 17
    void notifyPreviousTrack(boolean press);                       // tx 18
    void notifySystemSleep();                                      // tx 19
    void notifySystemWakeup();                                     // tx 20
    void notifyMotionEvent(in MotionEvent event);                  // tx 21
}
