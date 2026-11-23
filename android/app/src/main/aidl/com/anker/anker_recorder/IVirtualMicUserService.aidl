package com.anker.anker_recorder;

/**
 * Shizuku UserService running as shell — registers a system AudioPolicy
 * injector so other apps' AudioRecord(MIC / VOICE_*) read our PCM.
 */
interface IVirtualMicUserService {
    /** Start the virtual microphone injector. Returns status message. */
    String start();

    /** Stop and unregister the audio policy. */
    void stop();

    /** Write PCM16 LE mono @ 16 kHz from the D3200 bridge. */
    void writePcm16k(in byte[] pcm);

    boolean isRunning();

    String status();
}
