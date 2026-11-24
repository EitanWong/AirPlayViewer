// AirPlay screen-mirroring receiver built on UxPlay's protocol library (GPL-3.0).
// This file plays the part of UxPlay's own uxplay.cpp: it starts the library, answers its callbacks,
// keeps the Bonjour registrations serviced and restarts the listener when a sender goes silent.
#include "vpv_receiver.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "dnssd.h"
#include "logger.h"
#include "raop.h"
#include "stream.h"
#include "vpv_audio.h"

// Seconds without a heartbeat from a connected sender before the connection counts as lost.
// Senders send one every two seconds; UxPlay uses the same limit.
#define SILENCE_LIMIT_SECONDS 15

struct vpv_receiver {
    vpv_receiver_callbacks_t callbacks;
    raop_t *raop;
    dnssd_t *dnssd;
    unsigned short port;
    pthread_t service_thread;
    bool service_thread_started;
    int wakeup[2];
    atomic_bool stopping;
    atomic_bool restart_requested;
    atomic_bool mirroring;
    atomic_int silent_seconds;
    int silence_timeout;
    atomic_ushort audio_frames_per_packet;
    _Atomic float audio_gain;
    vpv_audio_t *audio; // Owned by the audio RTP thread.
    uint64_t audio_retry_at_ns;
};

static void report(vpv_receiver_t *receiver, int level, const char *message) {
    if (receiver->callbacks.log) {
        receiver->callbacks.log(receiver->callbacks.context, level, message);
    }
}

static void wake_service(vpv_receiver_t *receiver) {
    const char byte = 0;
    ssize_t written;
    do { written = write(receiver->wakeup[1], &byte, 1); } while (written < 0 && errno == EINTR);
    // EAGAIN means a wake is already pending.
}

static void free_receiver(vpv_receiver_t *receiver) {
    close(receiver->wakeup[0]);
    close(receiver->wakeup[1]);
    free(receiver);
}

// MARK: Callbacks from the protocol library

static void on_conn_feedback(void *cls) {
    vpv_receiver_t *receiver = cls;
    atomic_store(&receiver->silent_seconds, 0);
}

// The library lost the sender. The listener is restarted from the service thread,
// because this runs on one of the listener's own threads.
static void on_conn_reset(void *cls, int reason) {
    vpv_receiver_t *receiver = cls;
    (void) reason;
    report(receiver, LOGGER_WARNING, "lost the connection to the sender");
    atomic_store(&receiver->restart_requested, true);
    wake_service(receiver);
}

static void on_video_reset(void *cls, reset_type_t type) {
    vpv_receiver_t *receiver = cls;
    (void) type;
    if (receiver->callbacks.video_reset) {
        receiver->callbacks.video_reset(receiver->callbacks.context);
    }
}

static int on_video_set_codec_and_size(void *cls, video_codec_t codec, unsigned short width_source,
                                       unsigned short height_source, unsigned short x_offset,
                                       unsigned short y_offset, unsigned short width, unsigned short height) {
    vpv_receiver_t *receiver = cls;
    (void) x_offset; (void) y_offset; (void) width; (void) height;
    if (codec != VIDEO_CODEC_H264 && codec != VIDEO_CODEC_H265) {
        return -1;
    }
    if (receiver->callbacks.video_format) {
        receiver->callbacks.video_format(receiver->callbacks.context,
                                         codec == VIDEO_CODEC_H265 ? VPV_CODEC_H265 : VPV_CODEC_H264,
                                         (int) width_source, (int) height_source);
    }
    return 0;
}

static void on_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    vpv_receiver_t *receiver = cls;
    (void) ntp;
    atomic_store(&receiver->silent_seconds, 0);
    if (!receiver->callbacks.video_data || !data->data || data->data_len <= 0) {
        return;
    }
    receiver->callbacks.video_data(receiver->callbacks.context,
                                   data->is_h265 ? VPV_CODEC_H265 : VPV_CODEC_H264,
                                   data->data, data->data_len, data->ntp_time_local);
}

static void on_mirror_video_running(void *cls, bool is_running) {
    vpv_receiver_t *receiver = cls;
    atomic_store(&receiver->silent_seconds, 0);
    atomic_store(&receiver->mirroring, is_running);
    if (receiver->callbacks.mirror_running) {
        receiver->callbacks.mirror_running(receiver->callbacks.context, is_running);
    }
}

static void on_report_client_request(void *cls, char *deviceid, char *model, char *name, bool *admit) {
    vpv_receiver_t *receiver = cls;
    (void) deviceid;
    *admit = true;
    if (receiver->callbacks.client_request) {
        receiver->callbacks.client_request(receiver->callbacks.context, name ? name : "", model ? model : "");
    }
}

static void on_log(void *cls, int level, const char *message) {
    report(cls, level, message);
}

static void on_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    vpv_receiver_t *receiver = cls;
    (void) ntp;
    if (!data->data || data->data_len <= 0) return;
    if (!receiver->audio) {
        uint64_t now_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now_ns < receiver->audio_retry_at_ns) return;
        OSStatus status;
        receiver->audio = vpv_audio_create(data->ct, atomic_load(&receiver->audio_frames_per_packet), &status);
        if (!receiver->audio) {
            receiver->audio_retry_at_ns = now_ns + UINT64_C(1000000000);
            char message[100];
            snprintf(message, sizeof(message), "could not open AirPlay audio output (codec %u, status %d); retrying",
                     data->ct, (int) status);
            report(receiver, LOGGER_WARNING, message);
            return;
        }
    }
    if (!vpv_audio_enqueue(receiver->audio, data->data, (UInt32) data->data_len, atomic_load(&receiver->audio_gain))) {
        OSStatus status = vpv_audio_output_error(receiver->audio);
        if (status) {
            char message[100];
            snprintf(message, sizeof(message), "AirPlay audio output stopped (status %d); reopening", (int) status);
            report(receiver, LOGGER_WARNING, message);
            vpv_audio_destroy(receiver->audio);
            receiver->audio = NULL;
            receiver->audio_retry_at_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UINT64_C(250000000);
        }
    }
}

static void on_audio_flush(void *cls) {
    vpv_receiver_t *receiver = cls;
    vpv_audio_destroy(receiver->audio);
    receiver->audio = NULL;
    receiver->audio_retry_at_ns = 0;
}

static void on_audio_set_volume(void *cls, float volume) {
    vpv_receiver_t *receiver = cls;
    if (!isfinite(volume)) return;
    float gain = volume <= -144.0f ? 0.0f : powf(10.0f, fminf(0.0f, volume) / 20.0f);
    atomic_store(&receiver->audio_gain, gain);
}

static void on_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf, bool *usingScreen,
                                bool *isMedia, uint64_t *audioFormat) {
    vpv_receiver_t *receiver = cls;
    char message[120];
    snprintf(message, sizeof(message), "AirPlay audio SETUP: codec %u, frames %u, format 0x%llx, screen %d, media %d",
             *ct, *spf, (unsigned long long)*audioFormat, *usingScreen, *isMedia);
    report(receiver, LOGGER_NOTICE, message);
    atomic_store(&receiver->audio_frames_per_packet, *spf);
    atomic_store(&receiver->audio_gain, 1.0f);
}

// Metadata and the AirPlay video-player (HLS) protocol have no UI in this app.
static void on_video_pause(void *cls) { (void) cls; }
static void on_video_resume(void *cls) { (void) cls; }
static void on_video_flush(void *cls) { (void) cls; }
static double on_audio_set_client_volume(void *cls) { (void) cls; return 0.0; }
static void on_audio_set_metadata(void *cls, const void *buffer, int buflen) { (void) cls; (void) buffer; (void) buflen; }
static void on_audio_set_coverart(void *cls, const void *buffer, int buflen) { (void) cls; (void) buffer; (void) buflen; }
static void on_audio_stop_coverart_rendering(void *cls) { (void) cls; }
static void on_audio_remote_control_id(void *cls, const char *dacp_id, const char *active_remote_header) {
    (void) cls; (void) dacp_id; (void) active_remote_header;
}
static void on_audio_set_progress(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {
    (void) cls; (void) start; (void) curr; (void) end;
}
static void on_display_pin(void *cls, char *pin) { (void) cls; (void) pin; }
static void on_register_client(void *cls, const char *device_id, const char *pk_str, const char *name) {
    (void) cls; (void) device_id; (void) pk_str; (void) name;
}
static bool on_check_register(void *cls, const char *pk_str) { (void) cls; (void) pk_str; return true; }
static void on_export_dacp(void *cls, const char *active_remote, const char *dacp_id) {
    (void) cls; (void) active_remote; (void) dacp_id;
}
static void on_video_play(void *cls, const char *location, const float start_position) {
    (void) cls; (void) location; (void) start_position;
}
static void on_video_scrub(void *cls, const float position) { (void) cls; (void) position; }
static void on_video_rate(void *cls, const float rate) { (void) cls; (void) rate; }
static void on_video_stop(void *cls) { (void) cls; }
static void on_video_acquire_playback_info(void *cls, playback_info_t *playback_video) {
    (void) cls; (void) playback_video;
}
static float on_video_playlist_remove(void *cls) { (void) cls; return 0.0f; }
static void on_get_custom_profile(void *cls, const char **custom_profile) { (void) cls; *custom_profile = NULL; }

// MARK: Service thread

// Drops every connection and listens again on the same port, so the Bonjour registration stays valid.
static void restart_listener(vpv_receiver_t *receiver) {
    report(receiver, LOGGER_WARNING, "restarting the listener");
    raop_stop_httpd(receiver->raop);
    raop_remove_known_connections(receiver->raop);
    unsigned short port = receiver->port;
    if (raop_start_httpd(receiver->raop, &port) < 0) {
        report(receiver, LOGGER_ERR, "could not restart the listener");
        return;
    }
    receiver->port = port;
    raop_set_port(receiver->raop, port);
    atomic_store(&receiver->silent_seconds, 0);
}

// Wakes about once a second: services the Bonjour sockets, watches for silent senders.
static void *service_main(void *argument) {
    vpv_receiver_t *receiver = argument;
    pthread_setname_np("vpv.receiver.service");
    while (!atomic_load(&receiver->stopping)) {
        struct pollfd sockets[3] = {
            { receiver->wakeup[0], POLLIN, 0 },
            { dnssd_get_service_fd(receiver->dnssd, 0), POLLIN, 0 },
            { dnssd_get_service_fd(receiver->dnssd, 1), POLLIN, 0 },
        };
        int ready = poll(sockets, 3, 1000);
        if (atomic_load(&receiver->stopping)) {
            break;
        }
        if (ready < 0) {
            if (errno == EINTR) continue;
            report(receiver, LOGGER_ERR, "could not poll Bonjour sockets");
            break;
        }
        if (ready > 0) {
            if (sockets[0].revents & POLLIN) {
                char pending[64];
                (void) read(receiver->wakeup[0], pending, sizeof(pending));
            }
            for (int service = 0; service < 2; service++) {
                if (sockets[service + 1].revents & (POLLIN | POLLHUP | POLLERR)) {
                    dnssd_process_service(receiver->dnssd, service);
                }
            }
            // A burst of Bonjour traffic must not turn this loop into a faster clock.
        } else if (atomic_load(&receiver->mirroring)) {
            if (atomic_fetch_add(&receiver->silent_seconds, 1) + 1 > receiver->silence_timeout) {
                report(receiver, LOGGER_WARNING, "no heartbeat from the sender");
                atomic_store(&receiver->restart_requested, true);
            }
        } else {
            atomic_store(&receiver->silent_seconds, 0);
        }
        if (atomic_exchange(&receiver->restart_requested, false)) {
            restart_listener(receiver);
        }
    }
    return NULL;
}

// MARK: Public interface

vpv_receiver_t *vpv_receiver_start(const vpv_receiver_config_t *config,
                                   const vpv_receiver_callbacks_t *callbacks, int *error) {
    int unused = 0;
    if (!error) error = &unused;
    *error = 0;
    if (!config || !callbacks || !config->name || !config->name[0]) {
        *error = 1;
        return NULL;
    }
    vpv_receiver_t *receiver = calloc(1, sizeof(*receiver));
    if (!receiver) {
        *error = 1;
        return NULL;
    }
    if (pipe(receiver->wakeup) < 0) {
        *error = 2;
        free(receiver);
        return NULL;
    }
    for (int end = 0; end < 2; end++) {
        if (fcntl(receiver->wakeup[end], F_SETFL, O_NONBLOCK) < 0 ||
            fcntl(receiver->wakeup[end], F_SETFD, FD_CLOEXEC) < 0) {
            *error = 2;
            free_receiver(receiver);
            return NULL;
        }
    }
    receiver->callbacks = *callbacks;
    atomic_init(&receiver->audio_frames_per_packet, 0);
    atomic_init(&receiver->audio_gain, 1.0f);
    receiver->silence_timeout = config->mirror_silence_timeout > 0 ? config->mirror_silence_timeout : SILENCE_LIMIT_SECONDS;

    int dnssd_error = 0;
    receiver->dnssd = dnssd_init(config->name, (int) strlen(config->name),
                                 (const char *) config->device_id, 6, 0, &dnssd_error);
    if (dnssd_error || !receiver->dnssd) {
        *error = 2;
        free_receiver(receiver);
        return NULL;
    }
    // The feature set UxPlay advertises for a mirroring-only receiver (start_dnssd in uxplay.cpp).
    static const int on_bits[] = {1, 2, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 25, 27, 28, 30};
    static const int off_bits[] = {0, 3, 4, 8, 23, 24, 26, 29, 31};
    for (size_t i = 0; i < sizeof(on_bits) / sizeof(on_bits[0]); i++) {
        dnssd_set_airplay_features(receiver->dnssd, on_bits[i], 1);
    }
    for (size_t i = 0; i < sizeof(off_bits) / sizeof(off_bits[0]); i++) {
        dnssd_set_airplay_features(receiver->dnssd, off_bits[i], 0);
    }
    // Bit 42, "screen multi codec": the sender may use HEVC.
    dnssd_set_airplay_features(receiver->dnssd, 42, config->allow_h265 ? 1 : 0);

    raop_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.cls = receiver;
    cbs.conn_reset = on_conn_reset;
    cbs.conn_feedback = on_conn_feedback;
    cbs.audio_process = on_audio_process;
    cbs.video_process = on_video_process;
    cbs.video_pause = on_video_pause;
    cbs.video_resume = on_video_resume;
    cbs.video_reset = on_video_reset;
    cbs.video_set_codec_and_size = on_video_set_codec_and_size;
    cbs.audio_flush = on_audio_flush;
    cbs.video_flush = on_video_flush;
    cbs.audio_set_client_volume = on_audio_set_client_volume;
    cbs.audio_set_volume = on_audio_set_volume;
    cbs.audio_set_metadata = on_audio_set_metadata;
    cbs.audio_set_coverart = on_audio_set_coverart;
    cbs.audio_stop_coverart_rendering = on_audio_stop_coverart_rendering;
    cbs.audio_remote_control_id = on_audio_remote_control_id;
    cbs.audio_set_progress = on_audio_set_progress;
    cbs.audio_get_format = on_audio_get_format;
    cbs.mirror_video_running = on_mirror_video_running;
    cbs.report_client_request = on_report_client_request;
    cbs.display_pin = on_display_pin;
    cbs.register_client = on_register_client;
    cbs.check_register = on_check_register;
    cbs.export_dacp = on_export_dacp;
    cbs.on_video_play = on_video_play;
    cbs.on_video_scrub = on_video_scrub;
    cbs.on_video_rate = on_video_rate;
    cbs.on_video_stop = on_video_stop;
    cbs.on_video_acquire_playback_info = on_video_acquire_playback_info;
    cbs.on_video_playlist_remove = on_video_playlist_remove;
    cbs.get_custom_profile = on_get_custom_profile;
    // cbs.passwd stays NULL: any sender on the local network may connect, as with an Apple TV set to "Everyone".

    receiver->raop = raop_init(&cbs);
    if (!receiver->raop) {
        *error = 3;
        dnssd_destroy(receiver->dnssd);
        free_receiver(receiver);
        return NULL;
    }
    raop_set_log_callback(receiver->raop, on_log, receiver);
    raop_set_log_level(receiver->raop, config->log_level);

    char device_id[18];
    snprintf(device_id, sizeof(device_id), "%02x:%02x:%02x:%02x:%02x:%02x",
             config->device_id[0], config->device_id[1], config->device_id[2],
             config->device_id[3], config->device_id[4], config->device_id[5]);
    // nohold = 1: a new sender replaces the current one instead of being refused.
    if (raop_init2(receiver->raop, 1, device_id, config->key_file ? config->key_file : "")) {
        *error = 4;
        // raop_init2 leaves the half-built receiver to its caller, as UxPlay does.
        free(receiver->raop);
        dnssd_destroy(receiver->dnssd);
        free_receiver(receiver);
        return NULL;
    }
    if (config->width > 0) raop_set_plist(receiver->raop, "width", config->width);
    if (config->height > 0) raop_set_plist(receiver->raop, "height", config->height);
    if (config->refresh_rate > 0) raop_set_plist(receiver->raop, "refreshRate", config->refresh_rate);
    if (config->max_fps > 0) raop_set_plist(receiver->raop, "maxFPS", config->max_fps);

    // Port 0: the system picks free ports, so this never collides with the built-in receiver on 5000/7000.
    unsigned short tcp[3] = {0, 0, 0};
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(receiver->raop, tcp);
    raop_set_udp_ports(receiver->raop, udp);
    unsigned short port = raop_get_port(receiver->raop);
    if (raop_start_httpd(receiver->raop, &port) < 0) {
        *error = 5;
        raop_destroy(receiver->raop);
        dnssd_destroy(receiver->dnssd);
        free_receiver(receiver);
        return NULL;
    }
    receiver->port = port;
    raop_set_port(receiver->raop, port);
    raop_set_dnssd(receiver->raop, receiver->dnssd);

    if (dnssd_register_raop(receiver->dnssd, port) || dnssd_register_airplay(receiver->dnssd, port)) {
        *error = 6;
        dnssd_unregister_raop(receiver->dnssd);
        dnssd_unregister_airplay(receiver->dnssd);
        raop_destroy(receiver->raop);
        dnssd_destroy(receiver->dnssd);
        free_receiver(receiver);
        return NULL;
    }

    if (pthread_create(&receiver->service_thread, NULL, service_main, receiver) == 0) {
        receiver->service_thread_started = true;
    } else {
        report(receiver, LOGGER_ERR, "could not start the service thread");
    }
    return receiver;
}

void vpv_receiver_stop(vpv_receiver_t *receiver) {
    if (!receiver) return;
    atomic_store(&receiver->stopping, true);
    if (receiver->service_thread_started) {
        wake_service(receiver);
        pthread_join(receiver->service_thread, NULL);
    }
    dnssd_unregister_raop(receiver->dnssd);
    dnssd_unregister_airplay(receiver->dnssd);
    raop_destroy(receiver->raop);
    dnssd_destroy(receiver->dnssd);
    free_receiver(receiver);
}

uint16_t vpv_receiver_port(const vpv_receiver_t *receiver) {
    return receiver ? receiver->port : 0;
}

uint64_t vpv_receiver_now_ns(void) {
    return raop_ntp_get_local_time();
}
