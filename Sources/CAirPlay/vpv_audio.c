#include "vpv_audio.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { ALAC = 2, AAC_ELD = 8, BUFFER_COUNT = 32, MAX_FRAMES = 512, FRAME_BYTES = 4, MAX_PACKET_BYTES = 4096,
       SAMPLE_RATE = 44100, PREROLL_FRAMES = SAMPLE_RATE * 80 / 1000, QUEUE_LIMIT_FRAMES = SAMPLE_RATE / 4 };

static const AudioStreamBasicDescription stereo_pcm = {
    .mSampleRate = SAMPLE_RATE, .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    .mBytesPerPacket = FRAME_BYTES, .mFramesPerPacket = 1, .mBytesPerFrame = FRAME_BYTES,
    .mChannelsPerFrame = 2, .mBitsPerChannel = 16,
};

struct vpv_audio_decoder {
    AudioConverterRef converter;
    AudioStreamPacketDescription description;
    uint8_t last_packet[MAX_PACKET_BYTES];
    unsigned char codec;
};

OSStatus vpv_audio_decoder_create(unsigned char codec, unsigned short frames, vpv_audio_decoder_t **out) {
    AudioStreamBasicDescription format = {.mSampleRate = 44100, .mChannelsPerFrame = 2};
    // 24-byte ALACSpecificConfig: 16-bit stereo, 44.1 kHz, network byte order.
    uint8_t alac[] = {0, 0, 0x01, 0x60, 0, 16, 40, 10, 14, 2, 0, 255,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xac, 0x44};
    // AudioToolbox takes AAC's AudioSpecificConfig inside MPEG-4 ES descriptors.
    uint8_t eld[] = {0x03, 24, 0, 0, 0, 0x04, 19, 0x40, 0x15,
                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 4, 0xf8, 0xe8, 0x50, 0x00};
    const uint8_t *cookie;
    UInt32 cookie_size;
    switch (codec) {
        case ALAC:
            if (frames == 0) frames = 352;
            if (frames > MAX_FRAMES) return kAudioConverterErr_FormatNotSupported;
            alac[2] = frames >> 8;
            alac[3] = frames & 0xff;
            format.mFormatID = kAudioFormatAppleLossless;
            format.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData;
            cookie = alac;
            cookie_size = sizeof(alac);
            break;
        case AAC_ELD:
            if (frames == 0) frames = 480;
            if (frames != 480 && frames != 512) return kAudioConverterErr_FormatNotSupported;
            // The ELD frameLengthFlag selects 480 samples (one) or 512 (zero).
            if (frames == 512) eld[sizeof(eld) - 2] &= ~0x10;
            format.mFormatID = kAudioFormatMPEG4AAC_ELD;
            cookie = eld;
            cookie_size = sizeof(eld);
            break;
        default:
            return kAudioConverterErr_FormatNotSupported;
    }
    format.mFramesPerPacket = frames;
    vpv_audio_decoder_t *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) return ENOMEM;
    decoder->codec = codec;
    OSStatus status = AudioConverterNew(&format, &stereo_pcm, &decoder->converter);
    if (!status) {
        status = AudioConverterSetProperty(decoder->converter, kAudioConverterDecompressionMagicCookie, cookie_size, cookie);
    }
    if (status) {
        vpv_audio_decoder_destroy(decoder);
        return status;
    }
    *out = decoder;
    return noErr;
}

typedef struct {
    vpv_audio_decoder_t *decoder;
    const uint8_t *bytes;
    UInt32 size;
} decoder_input_t;

// A temporary lack of input is not EOF. Keep the converter alive between network packets.
enum { NEED_PACKET = 'vpvp' };

static OSStatus supply_packet(AudioConverterRef decoder, UInt32 *count, AudioBufferList *buffers,
                              AudioStreamPacketDescription **description, void *context) {
    (void) decoder;
    decoder_input_t *input = context;
    *count = input->bytes ? 1 : 0;
    if (!*count) return NEED_PACKET;
    // The converter may keep a pointer to the previous input until it calls back again.
    vpv_audio_decoder_t *state = input->decoder;
    memcpy(state->last_packet, input->bytes, input->size);
    state->description = (AudioStreamPacketDescription) {.mDataByteSize = input->size};
    buffers->mNumberBuffers = 1;
    buffers->mBuffers[0] = (AudioBuffer) {2, input->size, state->last_packet};
    if (description) *description = &state->description;
    input->bytes = NULL;
    return noErr;
}

OSStatus vpv_audio_decode(vpv_audio_decoder_t *decoder, const uint8_t *packet, UInt32 size,
                          void *samples, UInt32 *frames) {
    if (!size || size > MAX_PACKET_BYTES) return kAudioConverterErr_InvalidInputSize;
    // Wrong-key data can decode as loud noise. Check the stereo element and reserved bits first.
    if (decoder->codec == ALAC &&
        (size < 3 || packet[0] != 0x20 || packet[1] != 0 || (packet[2] & 0xe0))) {
        return kAudioConverterErr_FormatNotSupported;
    }
    decoder_input_t input = {.decoder = decoder, .bytes = packet, .size = size};
    AudioBufferList output = {.mNumberBuffers = 1, .mBuffers = {{2, *frames * FRAME_BYTES, samples}}};
    OSStatus status = AudioConverterFillComplexBuffer(decoder->converter, supply_packet, &input, frames, &output, NULL);
    return status == NEED_PACKET ? noErr : status;
}

void vpv_audio_decoder_destroy(vpv_audio_decoder_t *decoder) {
    if (!decoder) return;
    if (decoder->converter) AudioConverterDispose(decoder->converter);
    free(decoder);
}

struct vpv_audio {
    vpv_audio_decoder_t *decoder;
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[BUFFER_COUNT];
    atomic_uint pending_frames[BUFFER_COUNT];
    atomic_uint recycled;
    unsigned last_recycled;
    uint64_t last_progress_ns;
    uint64_t submitted_frames;
    OSStatus output_error;
    bool started;
    float gain;
};

static void recycle_buffer(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void) queue;
    vpv_audio_t *audio = context;
    atomic_store((atomic_uint *) buffer->mUserData, 0);
    atomic_fetch_add(&audio->recycled, 1);
}

vpv_audio_t *vpv_audio_create(unsigned char codec, unsigned short frames, OSStatus *status) {
    vpv_audio_t *audio = calloc(1, sizeof(*audio));
    if (!audio) { *status = ENOMEM; return NULL; }
    audio->gain = 1.0f;
    atomic_init(&audio->recycled, 0);
    *status = vpv_audio_decoder_create(codec, frames, &audio->decoder);
    if (*status == noErr) {
        *status = AudioQueueNewOutput(&stereo_pcm, recycle_buffer, audio, NULL, NULL, 0, &audio->queue);
    }
    for (int i = 0; i < BUFFER_COUNT && *status == noErr; i++) {
        atomic_init(&audio->pending_frames[i], 0);
        *status = AudioQueueAllocateBuffer(audio->queue, MAX_FRAMES * FRAME_BYTES, &audio->buffers[i]);
        if (*status == noErr) audio->buffers[i]->mUserData = &audio->pending_frames[i];
    }
    if (*status != noErr) {
        vpv_audio_destroy(audio);
        return NULL;
    }
    return audio;
}

bool vpv_audio_enqueue(vpv_audio_t *audio, const uint8_t *packet, UInt32 size, float gain) {
    if (audio->output_error) return false;

    double playback_headroom = 0;
    if (audio->started) {
        AudioTimeStamp time = {0};
        if (AudioQueueGetCurrentTime(audio->queue, NULL, &time, NULL) == noErr &&
            (time.mFlags & kAudioTimeStampSampleTimeValid)) {
            playback_headroom = (double)audio->submitted_frames - time.mSampleTime;
            if (playback_headroom <= 0) {
                // The device clock keeps advancing even when the queue has nothing to play.
                audio->output_error = AudioQueueStop(audio->queue, true);
                if (audio->output_error) return false;
                audio->submitted_frames = 0;
                audio->started = false;
            }
        }
    }

    int index = BUFFER_COUNT;
    unsigned pending = 0;
    for (int i = 0; i < BUFFER_COUNT; i++) {
        unsigned frames = atomic_load(&audio->pending_frames[i]);
        if (!frames && index == BUFFER_COUNT) index = i;
        pending += frames;
    }
    uint64_t now_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    unsigned recycled = atomic_load(&audio->recycled);
    if (recycled != audio->last_recycled) {
        audio->last_recycled = recycled;
        audio->last_progress_ns = now_ns;
    }

    int16_t pcm[MAX_FRAMES * 2];
    UInt32 frames = MAX_FRAMES;
    OSStatus status = vpv_audio_decode(audio->decoder, packet, size, pcm, &frames);
    if (status != noErr || frames == 0) return false;
    // Keep AAC decoder history even when a burst exceeds the playback budget.
    if (index == BUFFER_COUNT || pending + frames > QUEUE_LIMIT_FRAMES ||
        playback_headroom + frames > QUEUE_LIMIT_FRAMES) {
        if (audio->started && now_ns - audio->last_progress_ns >= 500 * UINT64_C(1000000)) {
            audio->output_error = ETIMEDOUT;
        }
        return false;
    }
    if (audio->gain != gain && AudioQueueSetParameter(audio->queue, kAudioQueueParam_Volume, gain) == noErr) {
        audio->gain = gain;
    }
    AudioQueueBufferRef buffer = audio->buffers[index];
    buffer->mAudioDataByteSize = frames * FRAME_BYTES;
    memcpy(buffer->mAudioData, pcm, buffer->mAudioDataByteSize);
    atomic_store(&audio->pending_frames[index], frames);
    audio->output_error = AudioQueueEnqueueBuffer(audio->queue, buffer, 0, NULL);
    if (audio->output_error) {
        atomic_store(&audio->pending_frames[index], 0);
        return false;
    }
    audio->submitted_frames += frames;
    if (!audio->started && audio->submitted_frames >= PREROLL_FRAMES) {
        audio->output_error = AudioQueueStart(audio->queue, NULL);
        audio->started = audio->output_error == noErr;
        audio->last_progress_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    }
    return audio->started;
}

OSStatus vpv_audio_output_error(const vpv_audio_t *audio) {
    return audio->output_error;
}

void vpv_audio_destroy(vpv_audio_t *audio) {
    if (!audio) return;
    if (audio->queue) AudioQueueDispose(audio->queue, true);
    vpv_audio_decoder_destroy(audio->decoder);
    free(audio);
}
