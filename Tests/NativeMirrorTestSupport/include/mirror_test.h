#ifndef VPV_MIRROR_TEST_H
#define VPV_MIRROR_TEST_H

#include <stdbool.h>

// Number of video connections closed by the receiver after a client FIN; -1 on setup failure.
int vpv_test_mirror_closes_and_reaccepts_video_socket(void);

// 1: replacement closed the stale socket; 0: timed out; -1: fixture setup failed.
int vpv_test_mirror_replaces_stale_video_socket(void);

// 1: timed-out partial packet was discarded and a new socket was serviced.
int vpv_test_mirror_recovers_from_partial_packet(bool partial_payload);

// 1: the decoder receives codec parameters without waiting for a video frame.
int vpv_test_mirror_delivers_configuration_independently(bool hevc);

// 1 if a compressed tone decodes to non-silent stereo PCM; 0 if unavailable.
int vpv_test_audio_decodes_tone(unsigned char compression_type, unsigned short frame_size);

// 1 when the decoder recognizes a full silent ALAC frame and rejects a corrupt header.
int vpv_test_alac_silence_and_header(void);

// 1 if macOS starts and restarts the default output queue with muted AAC-ELD audio.
int vpv_test_audio_output_reopens(void);

// 1 if tearing down the audio RTP thread flushes playback exactly once.
int vpv_test_audio_rtp_flushes_on_stop(void);

// Exercises actual loopback RTP delivery across packet loss and a paused stream.
int vpv_test_audio_rtp_recovers(bool flush, bool resend);
int vpv_test_audio_rtp_restarts(bool stale_flush);
int vpv_test_audio_rtp_delivers_without_clock(bool alac);
int vpv_test_audio_rtp_repeats_setup(void);

#endif
