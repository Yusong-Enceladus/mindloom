#ifndef BEST_ASR_PROCESS_TAP_RT_H
#define BEST_ASR_PROCESS_TAP_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BestASRProcessTapRTRecorder BestASRProcessTapRTRecorder;

BestASRProcessTapRTRecorder *BestASRProcessTapRTRecorderCreate(
    AudioObjectID deviceID,
    size_t maximumFrames);

OSStatus BestASRProcessTapRTRecorderStart(
    BestASRProcessTapRTRecorder *recorder);

void BestASRProcessTapRTRecorderStop(
    BestASRProcessTapRTRecorder *recorder);

void BestASRProcessTapRTRecorderDestroy(
    BestASRProcessTapRTRecorder *recorder);

size_t BestASRProcessTapRTRecorderCopySamples(
    const BestASRProcessTapRTRecorder *recorder,
    float *destination,
    size_t capacity);

// Removes up to `capacity` frames from the recorder's bounded single-producer,
// single-consumer ring. The Core Audio callback never allocates, locks, or
// performs file I/O; the Swift owner drains this method into the durable audio
// journal on a non-real-time task.
size_t BestASRProcessTapRTRecorderDrainSamples(
    BestASRProcessTapRTRecorder *recorder,
    float *destination,
    size_t capacity);

size_t BestASRProcessTapRTRecorderAvailableFrameCount(
    const BestASRProcessTapRTRecorder *recorder);

size_t BestASRProcessTapRTRecorderFrameCount(
    const BestASRProcessTapRTRecorder *recorder);

size_t BestASRProcessTapRTRecorderDroppedFrameCount(
    const BestASRProcessTapRTRecorder *recorder);

uint64_t BestASRProcessTapRTRecorderFirstHostTime(
    const BestASRProcessTapRTRecorder *recorder);

uint64_t BestASRProcessTapRTRecorderLastHostTime(
    const BestASRProcessTapRTRecorder *recorder);

uint64_t BestASRProcessTapRTRecorderCallbackCount(
    const BestASRProcessTapRTRecorder *recorder);

#ifdef __cplusplus
}
#endif

#endif
