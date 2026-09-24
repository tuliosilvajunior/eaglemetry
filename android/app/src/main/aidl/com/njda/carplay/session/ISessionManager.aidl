package com.njda.carplay.session;

import android.view.MotionEvent;
import com.njda.carplay.session.ISessionListener;

// The declaration order IS the wire. Each method takes the transaction code of
// its position, so a method that is added, removed or moved re-numbers every
// method below it. This order is copied 1:1 from the TRANSACTION_* constants of
// the unobfuscated stub in ConnAdaptor.apk
// (out/jadx/ConnAdaptor/sources/com/njda/carplay/session/ISessionManager.java:327-375).
// Only notifyMotionEvent (tx 14) is called today; the rest is here to hold the
// numbering true.
interface ISessionManager {
    void registerSessionListener(ISessionListener listener);       // tx 1
    boolean isDemoMode();                                          // tx 2
    boolean isProductActivated();                                  // tx 3
    boolean isCarplayCallActive();                                 // tx 4
    boolean isCarplayAlertActive();                                // tx 5
    boolean isCarplaySiriActive();                                 // tx 6
    boolean isCarplayNaviActive();                                 // tx 7
    boolean isCarplayMediaActive();                                // tx 8
    void notifyLocalVoice(int state);                              // tx 9
    void notifyLocalNavi(boolean active);                          // tx 10
    void notifyLocalCall(boolean active);                          // tx 11
    void notifyLocalMedia(boolean active);                         // tx 12
    void notifyESiriVoiceActivation(long wakeupTime);              // tx 13
    void notifyMotionEvent(in MotionEvent event);                  // tx 14
    void requestCarplayForeground(String reason);                  // tx 15
    void notifyMediaMute(boolean mute);                            // tx 16
    void notifyGlobalMute(boolean mute);                           // tx 17
    void notifyPhoneMute(boolean mute);                            // tx 18
    void notifyAcceptPhone(boolean press);                         // tx 19
    void notifyRejectPhone(boolean press);                         // tx 20
    void notifyFlashPhone(boolean press);                          // tx 21
    void notifyStartMedia(boolean press);                          // tx 22
    void notifyStopMedia(boolean press);                           // tx 23
    void notifyFlashMedia(boolean press);                          // tx 24
    void notifyVoiceKey(boolean press);                            // tx 25
    void notifyNextTrack(boolean press);                           // tx 26
    void notifyPreviousTrack(boolean press);                       // tx 27
    void notifyKnobEnter(boolean press);                           // tx 28
    void notifyKnobBack(boolean press);                            // tx 29
    void notifyKnobHome(boolean press);                            // tx 30
    void notifyKnobNext(boolean press);                            // tx 31
    void notifyKnobPrevious(boolean press);                        // tx 32
    void notifyKnobLeft(boolean press);                            // tx 33
    void notifyKnobRight(boolean press);                           // tx 34
    void notifyKnobDown(boolean press);                            // tx 35
    void notifyKnobUp(boolean press);                              // tx 36
    void notifyMediaSourceChange(boolean active);                  // tx 37
    void notifyShortcut(byte code);                                // tx 38
    void notifySystemSleep();                                      // tx 39
    void notifySystemWakeup();                                     // tx 40
    void notifyStandbyMode(boolean standby, boolean immediate);    // tx 41
    void notifyDisplayOFF(boolean off, boolean immediate);         // tx 42
    void notifyDisplayOFF_Ext(int state);                          // tx 43
    void notifyUiAllCover(boolean cover, boolean immediate);       // tx 44
    void notifyAudioFocusChange(int type, int state);              // tx 45
    void responsePermissionResult(boolean granted, int type);      // tx 46
    void requestCall(String number, int type);                     // tx 47
    boolean isConnected();                                         // tx 48
    boolean isForeground();                                        // tx 49
}
