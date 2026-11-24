// A small C interface to an AirPlay screen-mirroring receiver.
// The protocol is implemented by UxPlay's library (GPL-3.0), which this file keeps out of Swift's view.
#ifndef VPV_RECEIVER_H
#define VPV_RECEIVER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vpv_receiver vpv_receiver_t;

typedef enum {
    VPV_CODEC_H264 = 0,
    VPV_CODEC_H265 = 1,
} vpv_codec_t;

// Every callback runs on one of the receiver's own threads, never on the caller's.
// Pointers passed to a callback are valid only until it returns.
typedef struct {
    void *context;
    // A sender asked to connect.
    void (*client_request)(void *context, const char *name, const char *model);
    // The mirroring stream started (true) or ended (false).
    void (*mirror_running)(void *context, bool running);
    // The sender announced the codec and picture size of the video that follows.
    void (*video_format)(void *context, vpv_codec_t codec, int width, int height);
    // One packet of video as an Annex B byte stream (NAL units separated by 00 00 00 01).
    // `capture_time_ns` is the sender's capture time on this machine's clock (see vpv_receiver_now_ns),
    // or 0 while the clocks are not synchronised yet.
    void (*video_data)(void *context, vpv_codec_t codec, const uint8_t *data, int length,
                       uint64_t capture_time_ns);
    // The stream was interrupted. Decoding must start again from the next key frame.
    void (*video_reset)(void *context);
    // A message from the protocol library. Levels follow syslog: 3 error, 4 warning, 6 info, 7 debug.
    void (*log)(void *context, int level, const char *message);
} vpv_receiver_callbacks_t;

typedef struct {
    const char *name;        // shown in the sender's list of screens
    uint8_t device_id[6];    // stable identifier, formatted like a MAC address
    const char *key_file;    // PEM file that keeps the receiver's key pair between launches
    bool allow_h265;         // also accept HEVC video
    int width;               // largest picture the sender should send
    int height;
    int refresh_rate;
    int max_fps;
    int log_level;           // highest syslog level passed to `log`
    int mirror_silence_timeout; // seconds; 0 selects the default
} vpv_receiver_config_t;

// Starts listening and advertising. Returns NULL on failure and sets *error to the failing step (1-5).
vpv_receiver_t *vpv_receiver_start(const vpv_receiver_config_t *config,
                                   const vpv_receiver_callbacks_t *callbacks, int *error);

// Stops advertising, ends any session and frees the receiver. No callback runs after this returns.
void vpv_receiver_stop(vpv_receiver_t *receiver);

// TCP port the receiver listens on.
uint16_t vpv_receiver_port(const vpv_receiver_t *receiver);

// Current time on the clock used for `capture_time_ns`, in nanoseconds.
uint64_t vpv_receiver_now_ns(void);

#ifdef __cplusplus
}
#endif

#endif
