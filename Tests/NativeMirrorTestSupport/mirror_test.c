#include "mirror_test.h"
#include "../../Sources/CAirPlay/uxplay/raop_rtp_mirror.h"

#include <arpa/inet.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>

static void did_accept(void *context, int level, const char *message) {
    (void)level;
    if (!strcmp(message, "raop_rtp_mirror accepting client")) {
        const char accepted = 1;
        write(*(int *)context, &accepted, 1);
    }
}

static int exercise_video_socket_replacement(size_t prefix_length) {
    int notifications[2];
    if (pipe(notifications) != 0) return -1;
    int result = -1;
    int first = -1;
    int second = -1;
    logger_t *logger = logger_init();
    raop_callbacks_t callbacks = {0};
    timing_protocol_t protocol = TP_UNSPECIFIED;
    raop_ntp_t *timing = logger ? raop_ntp_init(logger, &callbacks, "127.0.0.1", 4, 0, &protocol) : NULL;
    unsigned char key[16] = {0};
    if (logger) {
        logger_set_level(logger, LOGGER_DEBUG);
        logger_set_callback(logger, did_accept, &notifications[1]);
    }
    raop_rtp_mirror_t *mirror = timing ? raop_rtp_mirror_init(
        logger, &callbacks, timing, "127.0.0.1", 4, key) : NULL;
    if (mirror) {
        unsigned short port = 0;
        raop_rtp_mirror_start(mirror, &port, 0);
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        first = socket(AF_INET, SOCK_STREAM, 0);
        second = socket(AF_INET, SOCK_STREAM, 0);
        struct pollfd accepted = {.fd = notifications[0], .events = POLLIN};
        // A complete header advertises four bytes of performance data; only one payload byte arrives.
        const unsigned char packet_prefix[129] = {[0] = 4, [4] = 0x05};
        if (port && first >= 0 && second >= 0 &&
            connect(first, (struct sockaddr *)&address, sizeof(address)) == 0 &&
            (!prefix_length || send(first, packet_prefix, prefix_length, 0) == (ssize_t)prefix_length) &&
            poll(&accepted, 1, 1000) == 1 &&
            connect(second, (struct sockaddr *)&address, sizeof(address)) == 0) {
            struct pollfd stale = {.fd = first, .events = POLLIN};
            struct pollfd replacement = {.fd = second, .events = POLLIN};
            char byte;
            result = poll(&stale, 1, prefix_length ? 3500 : 1000) == 1 &&
                recv(first, &byte, 1, 0) == 0 &&
                shutdown(second, SHUT_WR) == 0 &&
                poll(&replacement, 1, 1000) == 1 && recv(second, &byte, 1, 0) == 0;
        }
        raop_rtp_mirror_destroy(mirror);
    }
    if (first >= 0) close(first);
    if (second >= 0) close(second);
    raop_ntp_destroy(timing);
    if (logger) logger_destroy(logger);
    close(notifications[0]);
    close(notifications[1]);
    return result;
}

int vpv_test_mirror_replaces_stale_video_socket(void) {
    return exercise_video_socket_replacement(0);
}

int vpv_test_mirror_recovers_from_partial_packet(bool partial_payload) {
    return exercise_video_socket_replacement(partial_payload ? 129 : 1);
}

static int accept_codec(void *context, video_codec_t codec, unsigned short source_width,
                        unsigned short source_height, unsigned short x, unsigned short y,
                        unsigned short width, unsigned short height) {
    return 0;
}

struct config_observer {
    int notification;
    bool hevc;
};

static void capture_config(void *context, raop_ntp_t *timing, video_decode_struct *packet) {
    const struct config_observer *observer = context;
    const unsigned char h264[] = {0, 0, 0, 1, 0x67, 0x64, 0, 0x28, 0, 0, 0, 1, 0x68, 0xee, 0x3c};
    const unsigned char hevc[] = {0, 0, 0, 1, 0x40, 1, 0x0c, 0, 0, 0, 1, 0x42, 1, 0x60,
        0, 0, 0, 1, 0x44, 1, 0xc0};
    const size_t length = observer->hevc ? sizeof(hevc) : sizeof(h264);
    const char valid = packet->is_h265 == observer->hevc && packet->nal_count == (observer->hevc ? 3 : 2) &&
        packet->data_len == (int)length && !memcmp(packet->data, observer->hevc ? hevc : h264, length);
    write(observer->notification, &valid, 1);
}

int vpv_test_mirror_delivers_configuration_independently(bool hevc) {
    int notifications[2];
    if (pipe(notifications) != 0) return -1;
    int result = -1;
    logger_t *logger = logger_init();
    struct config_observer observer = {.notification = notifications[1], .hevc = hevc};
    raop_callbacks_t callbacks = {.cls = &observer, .video_process = capture_config,
        .video_set_codec_and_size = accept_codec};
    timing_protocol_t protocol = TP_UNSPECIFIED;
    raop_ntp_t *timing = logger ? raop_ntp_init(logger, &callbacks, "127.0.0.1", 4, 0, &protocol) : NULL;
    unsigned char key[16] = {0};
    raop_rtp_mirror_t *mirror = timing ? raop_rtp_mirror_init(
        logger, &callbacks, timing, "127.0.0.1", 4, key) : NULL;
    if (mirror) {
        unsigned short port = 0;
        raop_rtp_mirror_start(mirror, &port, 0);
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        const unsigned char h264_config[] = {1, 0x64, 0, 0x28, 0xff, 0xe1, 0, 4, 0x67, 0x64, 0, 0x28,
            1, 0, 3, 0x68, 0xee, 0x3c};
        const unsigned char hevc_config[] = {[4] = 'h', 'v', 'c', '1',
            [0x75] = 0xa0, 0, 1, 0, 3, 0x40, 1, 0x0c, 0xa1, 0, 1, 0, 3, 0x42, 1, 0x60,
            0xa2, 0, 1, 0, 3, 0x44, 1, 0xc0};
        const size_t length = hevc ? sizeof(hevc_config) : sizeof(h264_config);
        unsigned char bytes[128 + sizeof(hevc_config)] = {[4] = 0x01, [7] = 0x01};
        bytes[0] = (unsigned char)length;
        bytes[6] = hevc ? 0x1e : 0x16;
        memcpy(bytes + 128, hevc ? hevc_config : h264_config, length);
        int client = socket(AF_INET, SOCK_STREAM, 0);
        if (port && client >= 0 && connect(client, (struct sockaddr *)&address, sizeof(address)) == 0 &&
            send(client, bytes, 128 + length, 0) == (ssize_t)(128 + length)) {
            struct pollfd received = {.fd = notifications[0], .events = POLLIN};
            char valid = 0;
            result = poll(&received, 1, 1000) == 1 && read(notifications[0], &valid, 1) == 1 && valid == 1;
        }
        raop_rtp_mirror_destroy(mirror);
        if (client >= 0) close(client);
    }
    raop_ntp_destroy(timing);
    if (logger) logger_destroy(logger);
    close(notifications[0]);
    close(notifications[1]);
    return result;
}

int vpv_test_mirror_closes_and_reaccepts_video_socket(void) {
    int result = -1;
    logger_t *logger = logger_init();
    raop_callbacks_t callbacks = {0};
    struct in_addr loopback = {.s_addr = htonl(INADDR_LOOPBACK)};
    unsigned char key[16] = {0};
    // No encrypted packets or timing traffic are needed to exercise a clean TCP close.
    raop_rtp_mirror_t *mirror = logger ? raop_rtp_mirror_init(
        logger, &callbacks, NULL, "127.0.0.1", sizeof(loopback), key) : NULL;
    if (mirror) {
        unsigned short port = 0;
        raop_rtp_mirror_start(mirror, &port, 0);
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_port = htons(port), .sin_addr = loopback};
        if (port) {
            result = 0;
            // The same RTSP session can open another video socket without re-pairing.
            for (int attempt = 0; attempt < 2; attempt++) {
                int client = socket(AF_INET, SOCK_STREAM, 0);
                if (client < 0) break;
                struct pollfd readable = {.fd = client, .events = POLLIN};
                char byte;
                bool closed = connect(client, (struct sockaddr *)&address, sizeof(address)) == 0 &&
                    shutdown(client, SHUT_WR) == 0 && poll(&readable, 1, 1000) == 1 &&
                    recv(client, &byte, sizeof(byte), 0) == 0;
                close(client);
                if (!closed) break;
                result++;
            }
        }
        raop_rtp_mirror_destroy(mirror);
    }
    if (logger) logger_destroy(logger);
    return result;
}
