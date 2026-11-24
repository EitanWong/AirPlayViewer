#include "mirror_test.h"

#include "../../Sources/CAirPlay/vpv_audio.h"
#include "../../Sources/CAirPlay/uxplay/raop_rtp.h"
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>

// Raw packets from synthetic 44.1 kHz stereo tones, with no container or RTP header.
static const uint8_t eld480[] = {
    0x5a, 0x7b, 0xb3, 0x42, 0x84, 0xc4, 0xf7, 0xfe, 0xfe, 0xff, 0x1f, 0x5f,
    0x5d, 0x2a, 0x97, 0x54, 0x0b, 0x70, 0x8a, 0x38, 0xeb, 0xef, 0x8a, 0xcf,
    0xbf, 0xb5, 0xdd, 0x44, 0x8c, 0x4d, 0x5b, 0x95, 0x40, 0xa5, 0xf4, 0x52,
    0x64, 0x9d, 0xf1, 0x3a, 0x73, 0x71, 0x6d, 0xc5, 0x33, 0x43, 0x77, 0x54,
    0x41, 0x23, 0x10, 0x1e, 0x4d, 0xf5, 0x10, 0xf2, 0xc6, 0x66, 0x8a, 0x01,
    0x60, 0x60, 0x05, 0xad, 0xc2, 0x28, 0xe2, 0x21, 0x4b, 0x4b, 0x4b, 0x4b,
    0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
    0x4b, 0x4b, 0x4a,
};
static const uint8_t eld512[] = {
    0x65, 0xf8, 0x00, 0x00, 0x48, 0x20, 0xdc, 0x80, 0xa2, 0x28, 0x0c, 0x99,
    0xfa, 0x7e, 0x75, 0xff, 0xef, 0x74, 0x96, 0xb3, 0x22, 0x4e, 0xff, 0x11,
    0xf0, 0xf0, 0xf3, 0xa4, 0x92, 0x8b, 0xc7, 0xbd, 0xe1, 0x22, 0x8d, 0x63,
    0xed, 0x42, 0x07, 0xa4, 0x08, 0xe8, 0xac, 0x02, 0xfd, 0x00, 0x00, 0x02,
    0xd6, 0x64, 0x49, 0xdf, 0xe2, 0x3e, 0x1e, 0x1e,
};
static const uint8_t alac[] = {
    0x20, 0x00, 0x10, 0x00, 0x00, 0x00, 0x30, 0x00, 0x02, 0x0d, 0x0c, 0x01,
    0x47, 0xfe, 0xa0, 0x01, 0x01, 0xff, 0x58, 0x00, 0x53, 0xff, 0xee, 0x0f,
    0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0f, 0xf8, 0x07,
    0x0f, 0xfe, 0x01, 0xc4, 0xfe, 0x1b, 0xf7, 0x3f, 0xb1, 0xe4, 0x4c, 0xe3,
    0xa0, 0xe1, 0x82, 0x25, 0x02, 0x88, 0x00, 0x18, 0xe0, 0x81, 0x81, 0x08,
    0x20, 0xe5, 0x3c,
};
// A complete 352-sample frame, with the sample count taken from the stream config.
static const uint8_t alac_silence[] = {
    0x20, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x08, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x0f, 0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xff, 0x80, 0xaf, 0xbf, 0xe0, 0x2b, 0xfc,
};

int vpv_test_alac_silence_and_header(void) {
    vpv_audio_decoder_t *decoder = NULL;
    OSStatus status = vpv_audio_decoder_create(2, 352, &decoder);
    if (status) return (int)status;
    int16_t pcm[352 * 2];
    uint8_t invalid[sizeof(alac_silence)] = {0x68, 0x01, 0x20};
    UInt32 frames = 352;
    OSStatus rejected = vpv_audio_decode(decoder, invalid, sizeof(invalid), pcm, &frames);
    frames = 352;
    status = vpv_audio_decode(decoder, alac_silence, sizeof(alac_silence), pcm, &frames);
    vpv_audio_decoder_destroy(decoder);
    if (status) return (int)status;
    if (frames != 352 || rejected != kAudioConverterErr_FormatNotSupported) return 0;
    for (size_t i = 0; i < sizeof(pcm) / sizeof(pcm[0]); i++) {
        if (pcm[i] != 0) return 0;
    }
    return 1;
}

int vpv_test_audio_decodes_tone(unsigned char compression_type, unsigned short frame_size) {
    const bool lossless = compression_type == 2;
    const bool eld_short = frame_size != 512;
    const uint8_t *packet = lossless ? alac : (eld_short ? eld480 : eld512);
    const UInt32 packet_size = lossless ? sizeof(alac) : (eld_short ? sizeof(eld480) : sizeof(eld512));
    const UInt32 expected_frames = lossless ? 24 : (eld_short ? 480 : 512);
    int16_t pcm[512 * 2];
    vpv_audio_decoder_t *decoder = NULL;
    OSStatus status = vpv_audio_decoder_create(compression_type, frame_size, &decoder);
    if (status) return (int)status;
    UInt32 frames;
    for (int i = 0; i < 3; i++) {
        frames = sizeof(pcm) / sizeof(pcm[0]) / 2;
        status = vpv_audio_decode(decoder, packet, packet_size, pcm, &frames);
        if (status || frames != expected_frames) break;
    }
    vpv_audio_decoder_destroy(decoder);
    if (status) return (int)status;
    if (frames != expected_frames) return -(int)frames;
    for (UInt32 i = 0; i < frames * 2; i++) {
        if (pcm[i] > 32 || pcm[i] < -32) return 1;
    }
    return 0;
}

int vpv_test_audio_output_reopens(void) {
    for (int i = 0; i < 2; i++) {
        OSStatus status;
        vpv_audio_t *audio = vpv_audio_create(8, 480, &status);
        if (!audio) return (int)status;
        bool correct = true;
        for (int stream = 0; stream < 2 && correct; stream++) {
            for (int packet = 0; packet < 8; packet++) {
                bool started = vpv_audio_enqueue(audio, eld480, sizeof(eld480), 0.0f);
                if (started != (packet >= 7)) correct = false;
            }
            // Leaving the same queue idle must force it to build headroom again.
            if (stream == 0 && correct) usleep(900000);
        }
        vpv_audio_destroy(audio);
        if (!correct) return 0;
    }
    return 1;
}

static void count_flush(void *context) {
    ++*(int *)context;
}

int vpv_test_audio_rtp_flushes_on_stop(void) {
    logger_t *logger = logger_init();
    if (!logger) return -1;
    int flushes = 0;
    raop_callbacks_t callbacks = {.cls = &flushes, .audio_flush = count_flush};
    unsigned char key[16] = {0};
    raop_rtp_t *rtp = raop_rtp_init(logger, &callbacks, NULL, "127.0.0.1", 4, key, key);
    unsigned short control_remote = 0, control_local = 0, data_local = 0;
    unsigned char codec = 8;
    unsigned int sample_rate = 44100;
    if (rtp) {
        raop_rtp_start_audio(rtp, &control_remote, &control_local, &data_local, &codec, &sample_rate);
        raop_rtp_stop(rtp);
        raop_rtp_destroy(rtp);
    }
    logger_destroy(logger);
    return control_local && data_local ? flushes : -1;
}

enum { AUDIO_FLUSHED = -2, AUDIO_TIMED_OUT = -1 };

static void record_audio_flush(void *context) {
    int event = AUDIO_FLUSHED;
    write(*(int *)context, &event, sizeof(event));
}

static void record_audio_packet(void *context, raop_ntp_t *timing, audio_decode_struct *audio) {
    (void)timing;
    int event = audio->seqnum;
    write(*(int *)context, &event, sizeof(event));
}

static int read_event(int fd, int timeout_ms) {
    struct pollfd poller = {.fd = fd, .events = POLLIN};
    int result;
    if (poll(&poller, 1, timeout_ms) != 1) return AUDIO_TIMED_OUT;
    return read(fd, &result, sizeof(result)) == sizeof(result) ? result : AUDIO_TIMED_OUT;
}

static bool send_audio_datagram(int fd, unsigned short port, const uint8_t *data, size_t size) {
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
        .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    return sendto(fd, data, size, 0, (struct sockaddr *)&address, sizeof(address)) == (ssize_t)size;
}

static bool send_audio_sequence(int fd, unsigned short port, uint16_t seq) {
    uint8_t packet[15] = {0x80, 0x60, seq >> 8, seq & 0xff, 0, 0, 1, 0, 0, 0, 0, 0, 0x20, 0, 0};
    return send_audio_datagram(fd, port, packet, sizeof(packet));
}

int vpv_test_audio_rtp_recovers(bool flush, bool resend) {
    int events[2];
    if (pipe(events) != 0) return -10;
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    logger_t *logger = logger_init();
    raop_callbacks_t callbacks = {.cls = &events[1], .audio_flush = record_audio_flush,
        .audio_process = record_audio_packet};
    timing_protocol_t protocol = TP_UNSPECIFIED;
    raop_ntp_t *timing = logger ? raop_ntp_init(logger, &callbacks, "127.0.0.1", 4, 0, &protocol) : NULL;
    unsigned char key[16] = {0};
    raop_rtp_t *rtp = timing ? raop_rtp_init(logger, &callbacks, timing, "127.0.0.1", 4, key, key) : NULL;
    int result = -11;

    if (rtp && sender >= 0) {
        unsigned short control_remote = 1, control_local = 0, data_local = 0;
        unsigned char codec = 2;
        unsigned int sample_rate = 44100;
        raop_rtp_start_audio(rtp, &control_remote, &control_local, &data_local, &codec, &sample_rate);
        const uint8_t sync[20] = {0x80, 0xd4, 0, 4, 0, 0, 1, 0, 0xe0};
        if (control_local && data_local && send_audio_datagram(sender, control_local, sync, sizeof(sync)) &&
            send_audio_sequence(sender, data_local, 100) && read_event(events[0], 1000) == 100) {
            if (flush) {
                // The second packet has not arrived; discard pending data on either side of the pause.
                send_audio_sequence(sender, data_local, 102);
                raop_rtp_flush(rtp, 65535);
                result = read_event(events[0], 1000) == AUDIO_FLUSHED ? -12 : -13;
                if (result == -12 && send_audio_sequence(sender, data_local, 65534) &&
                    send_audio_sequence(sender, data_local, 65535) && send_audio_sequence(sender, data_local, 0)) {
                    result = read_event(events[0], 250) == 65535 && read_event(events[0], 250) == 0 ? 1 : -14;
                }
                if (result == 1) {
                    // No sequence in FLUSH; resumed audio may already be waiting on the socket.
                    raop_rtp_flush(rtp, -1);
                    result = send_audio_sequence(sender, data_local, 45000) &&
                        read_event(events[0], 250) == AUDIO_FLUSHED && read_event(events[0], 250) == 45000 ? 1 : -16;
                }
            } else if (resend) {
                // A control datagram alone must release recovered packets and the original successor.
                struct pollfd requests = {.fd = sender, .events = POLLIN};
                const uint8_t retry[19] = {0x80, 0xd6, 0, 1, 0x80, 0x60, 0, 101, 0, 0, 1, 0, 0, 0, 0, 0, 0x20};
                uint8_t request[8];
                result = send_audio_sequence(sender, data_local, 102) && poll(&requests, 1, 250) == 1 &&
                    recv(sender, request, sizeof(request), 0) == sizeof(request) && request[1] == 0xd5 && request[5] == 101 &&
                    send_audio_datagram(sender, control_local, retry, sizeof(retry)) &&
                    read_event(events[0], 250) == 101 && read_event(events[0], 250) == 102 ? 1 : -17;
            } else {
                // An unrecoverable gap must expire even if the stream sends nothing else.
                result = send_audio_sequence(sender, data_local, 102) &&
                    read_event(events[0], 250) == 102 ? 1 : -15;
            }
        }
    }
    raop_rtp_destroy(rtp);
    if (timing) raop_ntp_destroy(timing);
    if (logger) logger_destroy(logger);
    if (sender >= 0) close(sender);
    close(events[0]);
    close(events[1]);
    return result;
}

enum audio_restart_scenario { STALE_FLUSH, SEQUENCE_RESET, NO_CLOCK, REPEAT_SETUP };

static int exercise_audio_rtp_restart(enum audio_restart_scenario scenario, unsigned char codec) {
    int events[2];
    if (pipe(events) != 0) return -10;
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    logger_t *logger = logger_init();
    raop_callbacks_t callbacks = {.cls = &events[1], .audio_process = record_audio_packet};
    timing_protocol_t protocol = TP_UNSPECIFIED;
    raop_ntp_t *timing = logger ? raop_ntp_init(logger, &callbacks, "127.0.0.1", 4, 0, &protocol) : NULL;
    unsigned char key[16] = {0};
    raop_rtp_t *rtp = timing ? raop_rtp_init(logger, &callbacks, timing, "127.0.0.1", 4, key, key) : NULL;
    int result = -11;
    if (rtp && sender >= 0) {
        unsigned short remote = 1, control = 0, data = 0;
        unsigned int rate = 44100;
        if (scenario == STALE_FLUSH) raop_rtp_flush(rtp, 30000);
        raop_rtp_start_audio(rtp, &remote, &control, &data, &codec, &rate);
        const uint8_t sync[20] = {0x80, 0xd4, 0, 4, 0, 0, 1, 0, 0xe0};
        if (control && data && (scenario == NO_CLOCK || send_audio_datagram(sender, control, sync, sizeof(sync)))) {
            if (scenario == STALE_FLUSH || scenario == NO_CLOCK) {
                result = send_audio_sequence(sender, data, 100) && read_event(events[0], 100) == 100 ? 1 : -12;
            } else if (scenario == REPEAT_SETUP) {
                unsigned short second_control = 0, second_data = 0;
                raop_rtp_start_audio(rtp, &remote, &second_control, &second_data, &codec, &rate);
                result = second_control == control && second_data == data &&
                    send_audio_sequence(sender, second_data, 100) && read_event(events[0], 100) == 100 ? 1 : -15;
            } else if (send_audio_sequence(sender, data, 20000) && read_event(events[0], 1000) == 20000) {
                result = -13;
                for (uint16_t i = 100; i < 123; i++) {
                    if (!send_audio_sequence(sender, data, i)) break;
                    int event = read_event(events[0], 10);
                    if (event != AUDIO_TIMED_OUT) {
                        result = event >= 111 && event <= i ? 1 : -14;
                        break;
                    }
                }
            }
        }
    }
    raop_rtp_destroy(rtp);
    if (timing) raop_ntp_destroy(timing);
    if (logger) logger_destroy(logger);
    if (sender >= 0) close(sender);
    close(events[0]);
    close(events[1]);
    return result;
}

int vpv_test_audio_rtp_restarts(bool stale_flush) {
    return exercise_audio_rtp_restart(stale_flush ? STALE_FLUSH : SEQUENCE_RESET, 2);
}

int vpv_test_audio_rtp_delivers_without_clock(bool alac) {
    return exercise_audio_rtp_restart(NO_CLOCK, alac ? 2 : 8);
}

int vpv_test_audio_rtp_repeats_setup(void) {
    return exercise_audio_rtp_restart(REPEAT_SETUP, 8);
}
