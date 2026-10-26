# Open-weight models

## Muse Glimmer on this Mac

Checked on October 26, 2026 against the Hugging Face listings; nothing downloaded yet.

- **Official 4-bit GGUF:** Meta publishes it as `meta-models/Muse-Glimmer-30B-GGUF`. It holds `Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf` (16.8 GB) and the vision projector `mmproj-Muse-Glimmer-30B-Q4_K_M.gguf` (1.4 GB).
- **License and access:** Apache-2.0; no access request.
- **MLX builds:** `mlx-community` publishes them at 4, 5, 6 and 8 bits and bf16, for example `mlx-community/Muse-Glimmer-30B-4bit`.
- **Runtime:** llama.cpp 0.7.0 is available through Homebrew and runs GGUF models with an `mmproj` vision projector on Metal.
- **Fit:** about 18 GB of weights plus context, which fits a Mac with 36 GB of memory.

Next: download the GGUF pair, run it with `llama-server`, which serves an OpenAI-compatible endpoint, and measure load time, memory, and plan and critique latency on the fixtures. Results go here with the date.

## Muse Spark Open

816B total parameters, about 537 GB in NVFP4. It doesn't fit on a Mac and runs on Baseten (`meta-models/muse-spark-open-1026`) or Modal. It is waiting for provider credits.
