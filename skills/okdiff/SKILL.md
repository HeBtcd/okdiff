---
name: okdiff
description: Zero-dependency Zig 0.17 SIMD PNG pixel-measurement CLI, stdio NDJSON server, and TypeScript/Python bindings using Ottosson Oklab Euclidean deltaE (default) or odiff-compatible YIQ. Use for image comparison, diff renders, raw f32 delta fields, and visual regression pipelines.
---

# okdiff

`okdiff` reports measurements only; callers decide pass/fail verdicts from emitted counts.

## Contract

- Exit `0` whenever measurement completes (even when pixels differ); exit `2` on usage, I/O, or PNG decode errors (diagnostics written to `stderr`).
- Supported inputs: non-interlaced PNG color types `0`, `2`, `3`, `4`, `6` (1/2/4/8/16-bit high byte), alpha-blended onto `#ffffff` before diffing.

## CLI

```sh
zig build -Doptimize=ReleaseFast
okdiff <base.png> <comp.png> [out.png] [options]
okdiff <dirA> <dirB> [--diff-dir <outdir>] [options]
okdiff --server [options]
```

Options:
- `-t, --threshold <f>`: count pixels with normalized delta `> f` (finite `>= 0`; omitted counts every pixel whose `#ffffff`-blended color differs)
- `--metric <oklab|yiq>`: `oklab` (`maxDelta2 = 1.0`) or `yiq` (`maxDelta2 = 35215.0`); normalized delta is `sqrt(delta2 / maxDelta2)` in `[0, 1]`
- `--aa`, `--antialiasing`: count AA-heuristic pixels separately as `aaLike` (never subtracted from `nonidentical`/`overThreshold`)
- `--aa-color <hex>`: paint `aaLike` pixels (e.g. `#ffff00`)
- `--delta-map[=s]`: output grayscale normalized-delta PNG (`alpha=0` where unmeasured, finite scale `s >= 0`, default `1.0`)
- `--diff-mask`: render differing pixels on transparent background
- `--diff-overlay <f>`: base faded to white under counted pixels (`0 <= f <= 1`)
- `--diff-color <hex>`: counted pixel color (default `#ff0000`)
- `--no-diff-image`: skip output PNG
- `--output-diff-lines`, `--output-diff-cols`: include differing row/column indices (`diffLines`, `diffCols`)
- `-c, --crop <x1:y1-x2:y2>`: inclusive 0-based crop rectangle (`x1 <= x2`, `y1 <= y2`) applied to both images before comparison; out-of-bounds or inverted boxes error
- `-i, --ignore <x1:y1-x2:y2,...>`: excluded rectangles (`x1 <= x2`, `y1 <= y2`)
- `--delta-bin <path>`: write `u32 width, height` LE header followed by `width * height` `f32` LE normalized pixel deltas `sqrt(delta2 / maxDelta2)` (`NaN` in ignored regions and `base` overhang; `0` where identical)
- `--diff-dir <dir>`: write per-stem output PNGs in directory mode
- `-j, --threads <n>`: worker thread count (`0` = CPU count)
- `--png-level <1-9>`: deflate level for output PNGs (default `1`)
- `--json`: emit machine-readable JSON on `stdout`
- `--server`: read JSON-line requests from `stdin`, write JSON-line responses to `stdout`
- `--`: stop flag parsing

## `--json` and `--server` Schemas

Single pair / `--server` response fields:
- Required: `base` (`{w, h}`), `comp` (`{w, h}`), `identical`, `nonidentical` (`stem` in CLI/dir, `requestId` integer in server)
- Conditional: `ignored`, `ignoredDiff`, `threshold`, `overThreshold`, `aaLike`, `overhangBase`, `overhangBaseOpaque`, `overhangComp`, `overhangCompOpaque`, `diffLines`, `diffCols`, `error`

Directory mode (`--json`):
- `{"pairs": [...], "onlyInA"?: [...], "onlyInB"?: [...]}`

Server requests (`--server`):
- `{"requestId"?: integer, "command"?: "close" | "exit", "base", "comp", "diff"?, "threshold"?, "metric"?: "oklab" | "yiq", "antialiasing"?, "diffLines"?, "diffCols"?, "diffMask"?, "diffOverlay"?, "diffColor"?, "aaColor"?, "deltaMap"?, "deltaBin"?, "crop"?: {x1, y1, x2, y2}, "ignoreRegions"?: [{x1, y1, x2, y2}]}`

## TypeScript and Python Bindings

Binary resolution order: explicit argument, `OKDIFF_BIN`, `<repo>/zig-out/bin/okdiff[.exe]`, `./zig-out/bin/okdiff[.exe]`, `PATH`.

- TypeScript (`bindings/okdiff.ts`): `compare`, `compareSync`, `compareDir`, `readDeltaBin`, `readDeltaBinSync`, `resolveBinary`, `OkdiffServer`, `OkdiffError`
- Python (`bindings/okdiff.py`): `compare`, `compare_dir`, `read_delta_bin`, `resolve_binary`, `OkdiffServer`, `DeltaBin`, `OkdiffError`
