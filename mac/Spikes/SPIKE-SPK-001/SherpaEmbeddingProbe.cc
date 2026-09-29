#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "sherpa-onnx/csrc/speaker-embedding-extractor.h"
#include "sherpa-onnx/csrc/wave-reader.h"

namespace {

std::vector<float> Normalize(std::vector<float> embedding) {
  float sum = 0;
  for (float value : embedding) {
    sum += value * value;
  }
  const float norm = std::sqrt(sum);
  if (norm > 0) {
    for (float &value : embedding) {
      value /= norm;
    }
  }
  return embedding;
}

} // namespace

int main(int argc, char *argv[]) {
  if (argc != 5) {
    std::cerr << "usage: SherpaEmbeddingProbe <model> <manifest> <audio-dir> "
                 "<output>\n";
    return 64;
  }

  const std::string model_path = argv[1];
  const std::filesystem::path manifest_path = argv[2];
  const std::filesystem::path audio_directory = argv[3];
  const std::filesystem::path output_path = argv[4];

  std::ifstream manifest_stream(manifest_path);
  if (!manifest_stream) {
    std::cerr << "failed to open identity manifest\n";
    return 66;
  }
  nlohmann::json manifest;
  manifest_stream >> manifest;

  sherpa_onnx::SpeakerEmbeddingExtractorConfig config;
  config.model = model_path;
  config.num_threads = 1;
  config.debug = false;
  config.provider = "cpu";
  if (!config.Validate()) {
    std::cerr << "invalid speaker embedding configuration\n";
    return 65;
  }
  sherpa_onnx::SpeakerEmbeddingExtractor extractor(config);

  nlohmann::json records = nlohmann::json::array();
  for (const auto &entry : manifest.at("entries")) {
    const std::string sample_id = entry.at("sampleID").get<std::string>();
    const std::filesystem::path audio_path =
        audio_directory / (sample_id + ".wav");
    int32_t sample_rate = 0;
    bool read_ok = false;
    const std::vector<float> samples =
        sherpa_onnx::ReadWave(audio_path.string(), &sample_rate, &read_ok);
    if (!read_ok || sample_rate != 16000) {
      std::cerr << "invalid wave for " << sample_id << "\n";
      return 65;
    }

    auto stream = extractor.CreateStream();
    stream->AcceptWaveform(sample_rate, samples.data(), samples.size());
    stream->InputFinished();
    if (!extractor.IsReady(stream.get())) {
      std::cerr << "insufficient audio for " << sample_id << "\n";
      return 65;
    }
    records.push_back(
        {{"sampleID", sample_id},
         {"embedding", Normalize(extractor.Compute(stream.get()))}});
  }

  nlohmann::json output = {
      {"schemaVersion", 1},
      {"kind", "speaker-embedding-probe-output"},
      {"modelFamily", "sherpa-onnx-3dspeaker"},
      {"dimension", extractor.Dim()},
      {"records", records},
  };
  std::ofstream output_stream(output_path);
  if (!output_stream) {
    std::cerr << "failed to open output\n";
    return 73;
  }
  output_stream << output.dump(2) << '\n';
  return 0;
}
