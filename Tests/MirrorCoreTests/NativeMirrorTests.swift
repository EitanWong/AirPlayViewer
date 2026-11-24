import NativeMirrorTestSupport
import Testing

@Test func videoSocketClosesCleanlyAndCanReconnectWithoutControlTeardown() {
    #expect(vpv_test_mirror_closes_and_reaccepts_video_socket() == 2)
}

@Test func sameSenderCanReplaceAHalfOpenVideoSocket() {
    #expect(vpv_test_mirror_replaces_stale_video_socket() == 1)
}

@Test(arguments: [false, true])
func aStalledPartialVideoPacketDoesNotBlockReconnect(partialPayload: Bool) {
    #expect(vpv_test_mirror_recovers_from_partial_packet(partialPayload) == 1)
}

@Test(arguments: [false, true])
func codecConfigurationReachesTheDecoderWithoutAMatchingFrameTimestamp(hevc: Bool) {
    #expect(vpv_test_mirror_delivers_configuration_independently(hevc) == 1)
}
