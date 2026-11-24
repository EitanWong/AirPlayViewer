import Foundation
import NativeMirrorTestSupport
import Testing

@Test(arguments: [(UInt8(2), UInt16(352)), (8, 480), (8, 512), (8, 0)])
func airPlayAudioDecodesToAudiblePCM(compressionType: UInt8, frameSize: UInt16) {
    #expect(vpv_test_audio_decodes_tone(compressionType, frameSize) == 1)
}

@Test func alacRejectsACorruptHeaderWithoutLosingASilentFrame() {
    #expect(vpv_test_alac_silence_and_header() == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VPV_AUDIO_OUTPUT_SMOKE"] == "1"))
func defaultAudioOutputCanStartAndReopen() {
    #expect(vpv_test_audio_output_reopens() == 1)
}

@Test func audioTransportFlushesPlaybackWhenStopped() {
    #expect(vpv_test_audio_rtp_flushes_on_stop() == 1)
}

@Test(arguments: [(true, false), (false, false), (false, true)])
func audioTransportRecoversAfterPacketLossOrPause(flush: Bool, resend: Bool) {
    #expect(vpv_test_audio_rtp_recovers(flush, resend) == 1)
}

@Test(arguments: [true, false])
func audioTransportRecoversFromASequenceRestart(staleFlush: Bool) {
    #expect(vpv_test_audio_rtp_restarts(staleFlush) == 1)
}

@Test(arguments: [true, false])
func audioPlaybackReceivesPacketsEvenBeforeClockSync(alac: Bool) {
    #expect(vpv_test_audio_rtp_delivers_without_clock(alac) == 1)
}

@Test func repeatedAudioSetupReturnsThePortsAlreadyListening() {
    #expect(vpv_test_audio_rtp_repeats_setup() == 1)
}
