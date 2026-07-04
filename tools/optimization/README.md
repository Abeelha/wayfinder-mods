# WFQoL Engine.ini optimization

Clarity / visibility / FPS tuning for Wayfinder, keeping the game looking good.
Active file: `%LOCALAPPDATA%\Wayfinder\Saved\Config\WindowsNoEditor\Engine.ini`
(kept read-only so the game can't overwrite it). Backup: `Engine.ini.wfqol-bak`.

## WFQoL changes (search "WFQoL:" in Engine.ini)
- EmitterSpawnRateScale 2.0 -> 1.0  (doubled combat VFX = clutter + GPU cost)
- ParticleLODBias -2 -> 0, ParticleDistanceRelevanceScale 2.0 -> 1.0  (fewer/cheaper particles)
- SSR.Quality 4 -> 2  (screen-space reflections, big cost / tiny visual)
- VolumetricFog.GridSizeZ 128 -> 64  (half the fog volume cost, same look)
- DepthOfFieldQuality = 0  (no blur = clearer enemies/targets)

Prior stutter fixes already in file: DistanceFieldGI off, SkyLight per-frame off,
hair sample counts cut, AO radius/fade cut, streaming pool 6000, mip bias -1.

## Revert
Copy `Engine.ini.wfqol-bak` back over `Engine.ini` (unlock read-only first).
