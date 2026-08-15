# ComfyUI Launcher

Bootstrap-and-launch scripts for [ComfyUI](https://github.com/comfyanonymous/ComfyUI),
written for **AMD Ryzen AI Max ("Strix Halo")** machines — ASUS ProArt PX13/P16,
ROG Flow Z13, and similar.

These machines run ComfyUI through the **AMD AI Bundle** (a ROCm build of PyTorch
that exposes the integrated Radeon 8060S as a CUDA-compatible device), which gives
you a huge slice of the unified system memory as "VRAM" (≈84 GB on 128 GB systems).

## What it does

`comfyui-launcher.cmd` (Windows) and `comfyui-launcher.sh` (macOS/Linux) both:

1. find or create a Python venv (an existing AMD-bundle venv is reused, never rebuilt)
2. install `requirements.txt` — AMD ROCm torch is pulled from the correct index
   (idempotent: skipped when already satisfied)
3. launch `main.py`, wait until it responds, then open the browser

The source of truth for "is ComfyUI running" is whatever is actually listening on
the port — no PID file, verified against the process command line.

## Commands

```
comfyui-launcher start             # bootstrap + launch + open browser (default)
comfyui-launcher install           # bootstrap venv + deps only, do NOT launch
comfyui-launcher stop              # stop the running instance
comfyui-launcher status            # is it running? (exit 0/1)
comfyui-launcher --no-browser      # launch without opening the browser
```

## Quick start (ASUS Strix Halo, Windows)

1. Install the **AMD AI Bundle** (ships ComfyUI + a ROCm venv under
   `%LOCALAPPDATA%\AMD\AI_Bundle\ComfyUI`).
2. Drop `comfyui-launcher.cmd` next to `main.py` (or set `COMFYUI_APP` to that folder).
3. Run `comfyui-launcher.cmd`. First run installs dependencies; later runs are fast.

## Env overrides

| variable | meaning |
|---|---|
| `COMFYUI_APP` / `COMFYUI_ROOT` | folder containing `main.py` |
| `COMFYUI_VENV` | venv path (defaults: AMD bundle venv, else `<app>\venv`) |
| `COMFYUI_PORT` | port (default 8188) |

## Getting models

ComfyUI doesn't ship with models. Put them under `models/`:

- image checkpoints → `models/checkpoints/`
- diffusion models (Flux, Wan) → `models/diffusion_models/`
- text encoders → `models/text_encoders/`
- VAEs → `models/vae/`

The [ComfyUI-Manager](https://github.com/ltdrdata/ComfyUI-Manager) plugin (install it
into `custom_nodes/`) gives you a search-and-click model downloader inside the UI.

## Notes

- `comfyui-launcher.cmd` is CRLF; `comfyui-launcher.sh` is LF (see `.gitattributes`).
- If a venv loses `pip`, the launcher tries `python -m ensurepip` and otherwise stops
  — it will **never** delete a venv automatically.
