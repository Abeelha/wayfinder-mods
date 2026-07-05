# Universal Claude Code prompt — fix Wayfinder stutter / 1%-low frametime spikes

Paste the block below into Claude Code, filling the 4 params. Works for any rig.
Wayfinder is UE (Airship "Atlas"), DX12, ships **FSR 2 only**, EAC present-but-inactive
in the offline/co-op build. Stutter is software (shader-PSO comp + traversal/streaming +
frame-pacing), NOT a GPU limit — so this is a config + frame-pacing task, not "more GPU".

## Params
- `{VRAM_GB}` = GPU VRAM in GB (e.g. 16)
- `{RESOLUTION}` = target res (e.g. 1080p / 1440p)
- `{GPU_VENDOR}` = AMD-RDNA4 / AMD-other / NVIDIA / Intel
- `{REFRESH_HZ}` = monitor refresh (e.g. 165)

## Prompt
> Read the existing `Engine.ini` at `%LOCALAPPDATA%\Wayfinder\Saved\Config\WindowsNoEditor\Engine.ini`
> (older/codename builds: `%LOCALAPPDATA%\Atlas\Saved\Config\WindowsClient\`). If it's read-only,
> clear the flag, edit, then re-set read-only at the end (so the game can't revert it). Back it up first.
>
> Audit every cvar against this classification and produce a corrected file:
>
> **(A) Universal frametime-stability cvars — keep/add under `[SystemSettings]`:**
> - `r.OneFrameThreadLag=1` (render-thread pacing)
> - `r.GTSyncType=1` (sync game→render thread, safe mode)
> - `gc.TimeBetweenPurgingPendingKillObjects=120` (GC runs less often → kills the rhythmic 30–60s spikes; trades a little RAM)
> - `r.Streaming.LimitPoolSizeToVRAM=1`, `r.Streaming.FullyLoadUsedTextures=0`, `r.Streaming.HLODStrategy=2`
> - `r.ShaderPipelineCache.Enabled=1`, `r.PSOPrecaching=1` (help IF the game shipped the bundled cache; harmless otherwise)
>
> **(B) Hardware-scaled cvars — compute from params:**
> - `r.Streaming.PoolSize` = ~⅓ of `{VRAM_GB}`×1024 MB, clamped 2000–6000 (8GB→2500, 12GB→4500, 16GB→6000; drop 500 if texture pop-in)
> - `r.Streaming.MipBias=0` (or `-1` max for sharper textures; NEVER below -1 → shimmer/thrash)
>
> **(C) Placebo cvars — strip or comment out (ignored in shipped UE builds):**
> `r.CreateShadersOnLoad`, `r.UseShaderPredraw`, `r.Shaders.Optimize`, `r.UseShaderCaching`
>
> **Preserve** visual-clarity settings already present (motion blur / DoF / chromatic aberration / film grain OFF;
> reduced sky-atmosphere samples; reduced shadow cascades/res). Keep GPU-hog reductions (shadows, effects,
> volumetric fog) if the user is GPU-bound.
>
> Then output:
> 1. **Steam launch options:** `-dx12` (default) — offer `-dx11` to test (UE4-era games often stutter less on DX11 at some CPU cost; keep DX12 as fallback if DX11 crashes). Add `-ExecCmds="r.MaxCharacterRenderSize=128"` (community beta fix for character-appearance hitches, unverified on 1.0 but low-risk). Optional `-fullscreen` (exclusive fullscreen paces better than borderless here). Disable Steam/Discord/other overlays for the profile.
> 2. **`{GPU_VENDOR}`-aware driver + Windows checklist:**
>    - VRR ON (FreeSync/G-Sync) + VSync ON (driver, as VRR backstop) + **cap FPS 3–5 below `{REFRESH_HZ}`**. Try the in-engine `t.MaxFPS`/in-game cap first; if frametimes are uneven, use **RTSS** (smoothest). Community recipe for THIS game: RTSS cap below refresh + VSync on = the recurring 30–45s stutter disappears.
>    - AMD: Radeon Chill OFF, Anti-Lag test both, avoid one-click HYPR-RX (configure manually), AF 16x ON, MLAA OFF.
>    - **`{GPU_VENDOR}=AMD-RDNA4` only:** A/B test **Resizable BAR / SAM OFF** — RDNA4 has a sparse-memory quirk that worsens 1% lows in streaming-heavy UE titles; keep OFF if lows tighten (costs ~1s longer initial load).
>    - HAGS A/B test (some AMD UE titles stutter less with it OFF). Game Mode ON, High-performance power plan, close background apps.
>    - Clear shader caches after every driver update (PSO/driver caches rebuild; expect one-time first-run stutter after).
>    - Keep game on Gen4 NVMe (UE traversal streaming is bandwidth-sensitive). Verify BIOS/AGESA current + EXPO/DDR5 stable.
>
> Separate universal vs hardware-specific sections clearly. Set the file read-only at the end.

## FSR 4 note (RDNA4)
Adrenalin's "AMD FSR Upscaling" override CANNOT engage on Wayfinder (needs a signed FSR **3.1** DX12 DLL;
game is FSR **2**). Only route to FSR 4 = **OptiScaler** (DLSS-spoof → FSR4). See `AI-MEMORY.md` global for the
full recipe (proxy=dxgi.dll, fakenvapi spoof, Dx12Upscaler=fsr31 auto-loads FSR4.1.1 on RDNA4). Only for image
quality, not FPS — this rig doesn't need it for frames. EAC inactive = low injection risk (re-check if MP returns).

## Staged validation (do in order, benchmark a fixed 5-min loop each time)
1. Baseline (no config): NVMe, latest stable driver, VRR+VSync on, RTSS cap −3/−5, overlays off, sit at menu to precompile. If spikes vanish → stop.
2. Repeatable-spot stutter → apply the Engine.ini block above.
3. Character-appearance hitches → add `-ExecCmds="r.MaxCharacterRenderSize=128"`, test `-dx11`.
4. RDNA4 → test ReBAR/SAM OFF.
5. Upscaling last (image quality only).

Source: deep-dive research (validated July 2026) cross-referenced against a live-tuned Engine.ini.
Placebo-cvar and FSR-4-can't-engage findings are the key gotchas most guides get wrong.
