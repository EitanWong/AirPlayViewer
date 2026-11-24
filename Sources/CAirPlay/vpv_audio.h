#ifndef VPV_AUDIO_H
#define VPV_AUDIO_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>

typedef struct vpv_audio vpv_audio_t;
typedef struct vpv_audio_decoder vpv_audio_decoder_t;

// AirPlay 44.1 kHz stereo ALAC and AAC-ELD packets decode to interleaved signed 16-bit PCM.
OSStatus vpv_audio_decoder_create(unsigned char codec, unsigned short frames, vpv_audio_decoder_t **out);
OSStatus vpv_audio_decode(vpv_audio_decoder_t *decoder, const uint8_t *packet, UInt32 size,
                          void *samples, UInt32 *frames);
void vpv_audio_decoder_destroy(vpv_audio_decoder_t *decoder);

// The RTP thread owns the player; Core Audio only returns individual buffers to the pool.
vpv_audio_t *vpv_audio_create(unsigned char codec, unsigned short frames, OSStatus *status);
bool vpv_audio_enqueue(vpv_audio_t *audio, const uint8_t *packet, UInt32 size, float gain);
OSStatus vpv_audio_output_error(const vpv_audio_t *audio);
void vpv_audio_destroy(vpv_audio_t *audio);

#endif
