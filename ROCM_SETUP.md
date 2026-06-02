# ROCm + Ollama setup (WIP)

## Goal
Enable the AMD Radeon 780M iGPU (gfx1103, RDNA 3) for Ollama inference instead of CPU-only.

## System
- CPU: AMD Ryzen 7 8845HS (8C/16T)
- GPU: AMD Radeon 780M (gfx1103, integrated)
- RAM: 32 GB
- OS: Arch Linux
- ROCm packages: already installed (rocm-hip-sdk, rocm-opencl-sdk, etc.)
- Ollama: 0.24.0-1 from extra repos (no ROCm in the binary)

## What's done

### Override config created
`/etc/systemd/system/ollama.service.d/override.conf`:
```
[Service]
Environment="HSA_OVERRIDE_GFX_VERSION=11.0.0"
Environment="HIP_VISIBLE_DEVICES=0"
```

This tells Ollama to target the Radeon 780M. GPU is detected by ROCm (`/opt/rocm/bin/rocminfo` shows it), but ollama 0.24.0 binary isn't linked against ROCm.

### AUR attempt failed
`yay -S aur/ollama-rocm-git` — build failed due to upstream git ref issues.

## Next step (not yet done)
Run the official installer to replace ollama with the latest upstream binary (0.6.x) which includes ROCm support:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Then restart:
```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify with `journalctl -u ollama --no-pager -n 15 | tail -10` — should show `inference compute` with `library=hip` or ROCm, not `library=cpu`.

## Installed ollama models
- deepseek-coder:6.7b-base (3.8 GB) — yapper primary
- deepseek-coder:6.7b (3.8 GB)
- qwen2.5-coder:7b-base (4.7 GB) — yapper alternative
- qwen2.5-coder:7b (4.7 GB)
- qwen2.5-coder:1.5b (986 MB)
- gemma4:26b (17 GB) — chat model, not for yapper
- mistral:latest (4.4 GB) — chat model, not for yapper

## yapper.nvim
FIM-based inline code completion in Neovim. Currently uses CPU-only inference.
