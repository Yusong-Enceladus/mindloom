// The HAL lifecycle follows Apple's "Capturing system audio with Core Audio
// taps" sample. This probe keeps the real-time callback in C++ and performs
// only bounded copies into preallocated memory.

#include "BestASRProcessTapRT.h"

#include <algorithm>
#include <atomic>
#include <vector>

struct BestASRProcessTapRTRecorder {
  explicit BestASRProcessTapRTRecorder(
      AudioObjectID inDeviceID,
      size_t maximumFrames)
      : deviceID(inDeviceID), samples(maximumFrames, 0.0F) {}

  AudioObjectID deviceID = kAudioObjectUnknown;
  AudioDeviceIOProcID ioProcID = nullptr;
  std::vector<float> samples;
  // Monotonic producer/consumer positions make the callback and one draining
  // task a lock-free SPSC ring. They are intentionally never wrapped; the
  // modulo operation is used only for addressing the preallocated storage.
  std::atomic<uint64_t> writePosition{0};
  std::atomic<uint64_t> readPosition{0};
  std::atomic<size_t> frameCount{0};
  std::atomic<size_t> droppedFrameCount{0};
  std::atomic<uint64_t> firstHostTime{0};
  std::atomic<uint64_t> lastHostTime{0};
  std::atomic<uint64_t> callbackCount{0};
  std::atomic<bool> started{false};
};

static OSStatus ProcessTapIOProc(
    AudioObjectID,
    const AudioTimeStamp *,
    const AudioBufferList *inputData,
    const AudioTimeStamp *inputTime,
    AudioBufferList *,
    const AudioTimeStamp *,
    void *clientData) noexcept {
  auto *recorder = static_cast<BestASRProcessTapRTRecorder *>(clientData);
  if (recorder == nullptr || inputData == nullptr ||
      inputData->mNumberBuffers == 0) {
    return kAudioHardwareNoError;
  }

  recorder->callbackCount.fetch_add(1, std::memory_order_relaxed);
  if (inputTime != nullptr) {
    const uint64_t hostTime = inputTime->mHostTime;
    uint64_t expected = 0;
    recorder->firstHostTime.compare_exchange_strong(
        expected,
        hostTime,
        std::memory_order_relaxed);
    recorder->lastHostTime.store(hostTime, std::memory_order_relaxed);
  }

  for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers;
       ++bufferIndex) {
    const AudioBuffer &buffer = inputData->mBuffers[bufferIndex];
    if (buffer.mData == nullptr || buffer.mNumberChannels == 0) {
      continue;
    }

    const size_t channelCount = buffer.mNumberChannels;
    const size_t availableFrames =
        buffer.mDataByteSize / (sizeof(float) * channelCount);
    const auto *source = static_cast<const float *>(buffer.mData);
    const uint64_t write =
        recorder->writePosition.load(std::memory_order_relaxed);
    const uint64_t read =
        recorder->readPosition.load(std::memory_order_acquire);
    const size_t occupied = static_cast<size_t>(write - read);
    const size_t remaining = occupied < recorder->samples.size()
        ? recorder->samples.size() - occupied
        : 0;
    const size_t framesToCopy = std::min(availableFrames, remaining);

    for (size_t frame = 0; frame < framesToCopy; ++frame) {
      float mixed = 0.0F;
      for (size_t channel = 0; channel < channelCount; ++channel) {
        mixed += source[frame * channelCount + channel];
      }
      const size_t destinationIndex =
          static_cast<size_t>((write + frame) % recorder->samples.size());
      recorder->samples[destinationIndex] = mixed / channelCount;
    }

    recorder->writePosition.store(
        write + framesToCopy,
        std::memory_order_release);
    recorder->frameCount.fetch_add(framesToCopy, std::memory_order_relaxed);
    if (framesToCopy < availableFrames) {
      recorder->droppedFrameCount.fetch_add(
          availableFrames - framesToCopy,
          std::memory_order_relaxed);
    }
  }

  return kAudioHardwareNoError;
}

BestASRProcessTapRTRecorder *BestASRProcessTapRTRecorderCreate(
    AudioObjectID deviceID,
    size_t maximumFrames) {
  if (deviceID == kAudioObjectUnknown || maximumFrames == 0) {
    return nullptr;
  }
  return new BestASRProcessTapRTRecorder(deviceID, maximumFrames);
}

OSStatus BestASRProcessTapRTRecorderStart(
    BestASRProcessTapRTRecorder *recorder) {
  if (recorder == nullptr) {
    return kAudio_ParamError;
  }
  if (recorder->started.load(std::memory_order_acquire)) {
    return kAudioHardwareNoError;
  }

  AudioDeviceIOProcID ioProcID = nullptr;
  OSStatus status = AudioDeviceCreateIOProcID(
      recorder->deviceID,
      ProcessTapIOProc,
      recorder,
      &ioProcID);
  if (status != kAudioHardwareNoError) {
    return status;
  }

  recorder->ioProcID = ioProcID;
  status = AudioDeviceStart(recorder->deviceID, recorder->ioProcID);
  if (status != kAudioHardwareNoError) {
    AudioDeviceDestroyIOProcID(recorder->deviceID, recorder->ioProcID);
    recorder->ioProcID = nullptr;
    return status;
  }

  recorder->started.store(true, std::memory_order_release);
  return kAudioHardwareNoError;
}

void BestASRProcessTapRTRecorderStop(
    BestASRProcessTapRTRecorder *recorder) {
  if (recorder == nullptr ||
      !recorder->started.exchange(false, std::memory_order_acq_rel)) {
    return;
  }
  AudioDeviceStop(recorder->deviceID, recorder->ioProcID);
  AudioDeviceDestroyIOProcID(recorder->deviceID, recorder->ioProcID);
  recorder->ioProcID = nullptr;
}

void BestASRProcessTapRTRecorderDestroy(
    BestASRProcessTapRTRecorder *recorder) {
  if (recorder == nullptr) {
    return;
  }
  BestASRProcessTapRTRecorderStop(recorder);
  delete recorder;
}

size_t BestASRProcessTapRTRecorderCopySamples(
    const BestASRProcessTapRTRecorder *recorder,
    float *destination,
    size_t capacity) {
  if (recorder == nullptr || destination == nullptr || capacity == 0) {
    return 0;
  }
  const uint64_t read =
      recorder->readPosition.load(std::memory_order_acquire);
  const uint64_t write =
      recorder->writePosition.load(std::memory_order_acquire);
  const size_t count = std::min(
      static_cast<size_t>(write - read),
      capacity);
  for (size_t index = 0; index < count; ++index) {
    destination[index] = recorder->samples[
        static_cast<size_t>((read + index) % recorder->samples.size())];
  }
  return count;
}

size_t BestASRProcessTapRTRecorderDrainSamples(
    BestASRProcessTapRTRecorder *recorder,
    float *destination,
    size_t capacity) {
  if (recorder == nullptr || destination == nullptr || capacity == 0) {
    return 0;
  }
  const uint64_t read =
      recorder->readPosition.load(std::memory_order_relaxed);
  const uint64_t write =
      recorder->writePosition.load(std::memory_order_acquire);
  const size_t count = std::min(
      static_cast<size_t>(write - read),
      capacity);
  for (size_t index = 0; index < count; ++index) {
    destination[index] = recorder->samples[
        static_cast<size_t>((read + index) % recorder->samples.size())];
  }
  recorder->readPosition.store(read + count, std::memory_order_release);
  return count;
}

size_t BestASRProcessTapRTRecorderAvailableFrameCount(
    const BestASRProcessTapRTRecorder *recorder) {
  if (recorder == nullptr) {
    return 0;
  }
  const uint64_t read =
      recorder->readPosition.load(std::memory_order_acquire);
  const uint64_t write =
      recorder->writePosition.load(std::memory_order_acquire);
  return static_cast<size_t>(write - read);
}

size_t BestASRProcessTapRTRecorderFrameCount(
    const BestASRProcessTapRTRecorder *recorder) {
  return recorder == nullptr
      ? 0
      : recorder->frameCount.load(std::memory_order_acquire);
}

size_t BestASRProcessTapRTRecorderDroppedFrameCount(
    const BestASRProcessTapRTRecorder *recorder) {
  return recorder == nullptr
      ? 0
      : recorder->droppedFrameCount.load(std::memory_order_relaxed);
}

uint64_t BestASRProcessTapRTRecorderFirstHostTime(
    const BestASRProcessTapRTRecorder *recorder) {
  return recorder == nullptr
      ? 0
      : recorder->firstHostTime.load(std::memory_order_relaxed);
}

uint64_t BestASRProcessTapRTRecorderLastHostTime(
    const BestASRProcessTapRTRecorder *recorder) {
  return recorder == nullptr
      ? 0
      : recorder->lastHostTime.load(std::memory_order_relaxed);
}

uint64_t BestASRProcessTapRTRecorderCallbackCount(
    const BestASRProcessTapRTRecorder *recorder) {
  return recorder == nullptr
      ? 0
      : recorder->callbackCount.load(std::memory_order_relaxed);
}
