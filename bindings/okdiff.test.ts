import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, test } from "node:test";
import zlib from "node:zlib";
import {
  OkdiffError,
  OkdiffServer,
  compare,
  compareDir,
  compareSync,
  readDeltaBin,
  readDeltaBinSync,
  resolveBinary,
  type DiffReport,
  type ServerRequest,
} from "./okdiff.ts";

type Rgba = readonly [number, number, number, number];
type PixelFn = (x: number, y: number) => Rgba;

interface DecodedPng {
  width: number;
  height: number;
  colorType: number;
  data: Uint8Array;
}

const PNG_SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type: string, data: Buffer): Buffer {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

function makeRgbaPng(width: number, height: number, pixel: PixelFn): Buffer {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const stride = 1 + width * 4;
  const raw = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const row = y * stride;
    raw[row] = 0;
    for (let x = 0; x < width; x++) {
      const [r, g, b, a] = pixel(x, y);
      const off = row + 1 + x * 4;
      raw[off] = r;
      raw[off + 1] = g;
      raw[off + 2] = b;
      raw[off + 3] = a;
    }
  }
  return Buffer.concat([
    PNG_SIG,
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", zlib.deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function paethPredictor(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

function decodePngRgba(buf: Buffer): DecodedPng {
  assert.ok(buf.subarray(0, 8).equals(PNG_SIG), "expected valid PNG signature");
  let pos = 8;
  let width = 0;
  let height = 0;
  let colorType = 0;
  const idats: Buffer[] = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.subarray(pos + 4, pos + 8).toString("ascii");
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.equal(data[8], 8);
      colorType = data[9];
    } else if (type === "IDAT") {
      idats.push(data);
    } else if (type === "IEND") {
      break;
    }
    pos += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idats));
  const bpp = colorType === 6 ? 4 : colorType === 2 ? 3 : colorType === 4 ? 2 : 1;
  const stride = width * bpp;
  const pixels = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (1 + stride)];
    const rowIn = y * (1 + stride) + 1;
    const rowOut = y * stride;
    for (let i = 0; i < stride; i++) {
      const x = raw[rowIn + i];
      const a = i >= bpp ? pixels[rowOut + i - bpp] : 0;
      const b = y > 0 ? pixels[rowOut - stride + i] : 0;
      const c = y > 0 && i >= bpp ? pixels[rowOut - stride + i - bpp] : 0;
      let val = x;
      if (filter === 1) val = (x + a) & 0xff;
      else if (filter === 2) val = (x + b) & 0xff;
      else if (filter === 3) val = (x + ((a + b) >> 1)) & 0xff;
      else if (filter === 4) val = (x + paethPredictor(a, b, c)) & 0xff;
      pixels[rowOut + i] = val;
    }
  }
  return { width, height, colorType, data: pixels };
}

function pixelAt(img: DecodedPng, x: number, y: number): [number, number, number, number] {
  assert.equal(img.colorType, 6);
  const off = (y * img.width + x) * 4;
  return [img.data[off], img.data[off + 1], img.data[off + 2], img.data[off + 3]];
}

async function withTempDir<T>(fn: (dir: string) => Promise<T> | T): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "okdiff-e2e-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function writePng(filePath: string, width: number, height: number, pixel: PixelFn): string {
  writeFileSync(filePath, makeRgbaPng(width, height, pixel));
  return filePath;
}

const WHITE: Rgba = [255, 255, 255, 255];
const BLACK: Rgba = [0, 0, 0, 255];

function makeDiagBase(size = 10): PixelFn {
  return (x, y) => (x === y ? BLACK : WHITE);
}

function makeDiagComp(size = 10): PixelFn {
  return (x, y) => {
    if (x === y) return BLACK;
    if (Math.abs(x - y) === 1 && x >= 2 && x <= size - 3) return [128, 128, 128, 255];
    return WHITE;
  };
}

describe("resolveBinary", () => {
  test("prefers explicit argument, then OKDIFF_BIN, then local zig-out/bin auto-discovery", () => {
    const prev = process.env.OKDIFF_BIN;
    const expectedName = process.platform === "win32" ? "okdiff.exe" : "okdiff";
    try {
      process.env.OKDIFF_BIN = path.join("custom", "env", expectedName);
      assert.equal(resolveBinary(path.join("explicit", "bin", expectedName)), path.join("explicit", "bin", expectedName));
      assert.equal(resolveBinary(), path.join("custom", "env", expectedName));

      delete process.env.OKDIFF_BIN;
      const discovered = resolveBinary();
      assert.equal(path.basename(discovered), expectedName);
      assert.ok(discovered.includes(path.join("zig-out", "bin")));
      assert.ok(existsSync(discovered), `expected auto-discovered binary at ${discovered}`);
    } finally {
      if (prev === undefined) delete process.env.OKDIFF_BIN;
      else process.env.OKDIFF_BIN = prev;
    }
  });
});

describe("compare and compareSync", () => {
  test("measures identical and differing PNGs in both async and sync APIs", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 4, 4, () => WHITE);
      const aCopy = writePng(path.join(dir, "a-copy.png"), 4, 4, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 4, 4, (x, y) =>
        (x === 1 && y === 0) || (x === 3 && y === 2) ? BLACK : WHITE,
      );

      for (const same of [await compare(a, aCopy, ["--no-diff-image"]), compareSync(a, aCopy, ["--no-diff-image"])]) {
        assert.deepEqual(same.base, { w: 4, h: 4 });
        assert.deepEqual(same.comp, { w: 4, h: 4 });
        assert.equal(same.identical, 16);
        assert.equal(same.nonidentical, 0);
        assert.equal(same.overThreshold, undefined);
        assert.equal(same.aaLike, undefined);
        assert.equal(same.ignored, undefined);
        assert.equal(same.overhangBase, undefined);
        assert.equal(same.overhangComp, undefined);
        assert.equal(same.diffLines, undefined);
        assert.equal(same.diffCols, undefined);
      }

      for (const diff of [await compare(a, b, ["--no-diff-image"]), compareSync(a, b, ["--no-diff-image"])]) {
        assert.deepEqual(diff.base, { w: 4, h: 4 });
        assert.deepEqual(diff.comp, { w: 4, h: 4 });
        assert.equal(diff.identical, 14);
        assert.equal(diff.nonidentical, 2);
      }
    });
  });

  test("distinguishes --metric oklab and --metric yiq scales and threshold counts", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 4, 4, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 4, 4, (x, y) => {
        if (x === 0 && y === 0) return [240, 240, 240, 255];
        if (x === 3 && y === 3) return BLACK;
        return WHITE;
      });
      const okBinPath = path.join(dir, "ok.bin");
      const yiqBinPath = path.join(dir, "yiq.bin");

      const okRes = await compare(a, b, ["--no-diff-image", "--metric", "oklab", "-t", "0.05", "--delta-bin", okBinPath]);
      const yiqRes = compareSync(a, b, ["--no-diff-image", "--metric", "yiq", "-t", "0.05", "--delta-bin", yiqBinPath]);

      assert.equal(okRes.nonidentical, 2);
      assert.equal(okRes.overThreshold, 1);
      assert.equal(yiqRes.nonidentical, 2);
      assert.equal(yiqRes.overThreshold, 2);

      const okSub = await compare(a, b, ["--no-diff-image", "--metric", "oklab", "-t", "0.1"]);
      const okZero = compareSync(a, b, ["--no-diff-image", "--metric", "oklab", "-t", "0"]);
      assert.equal(okSub.threshold, 0.1);
      assert.equal(okSub.nonidentical, 2);
      assert.equal(okSub.overThreshold, 1);
      assert.equal(okZero.threshold, 0);
      assert.equal(okZero.overThreshold, 2);

      const yiqMid = await compare(a, b, ["--no-diff-image", "--metric", "yiq", "-t", "0.1"]);
      assert.equal(yiqMid.nonidentical, 2);
      assert.equal(yiqMid.overThreshold, 1);

      const okDelta = await readDeltaBin(okBinPath);
      const yiqDelta = readDeltaBinSync(yiqBinPath);
      assert.ok(okDelta.data.every((d) => d >= 0 && d <= 1));
      assert.ok(yiqDelta.data.every((d) => d >= 0 && d <= 1));
      assert.ok(okDelta.data[0] > 0 && okDelta.data[0] < 0.05);
      assert.ok(okDelta.data[15] > 0.9 && okDelta.data[15] <= 1);
      assert.ok(yiqDelta.data[0] > 0.05 && yiqDelta.data[0] < 0.1);
      assert.ok(yiqDelta.data[15] > 0.9 && yiqDelta.data[15] <= 1);
      assert.notEqual(okDelta.data[0], yiqDelta.data[0]);
      assert.equal(Array.from(okDelta.data).filter((d) => d > 0.05).length, okRes.overThreshold);
      assert.equal(Array.from(yiqDelta.data).filter((d) => d > 0.05).length, yiqRes.overThreshold);
      assert.equal(Array.from(yiqDelta.data).filter((d) => d > 0.1).length, yiqMid.overThreshold);
    });
  });

  test("counts --aa pixels as aaLike without subtracting from nonidentical or overThreshold", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "diag1.png"), 10, 10, makeDiagBase(10));
      const b = writePng(path.join(dir, "diag2.png"), 10, 10, makeDiagComp(10));

      const withoutAa = await compare(a, b, ["--no-diff-image"]);
      const withAa = await compare(a, b, ["--no-diff-image", "--aa"]);
      const withAaThresh = compareSync(a, b, ["--no-diff-image", "--antialiasing", "-t", "0.1"]);
      const noAaThresh = compareSync(a, b, ["--no-diff-image", "-t", "0.1"]);

      assert.equal(withoutAa.aaLike, undefined);
      assert.equal(withoutAa.nonidentical, 12);
      assert.equal(withAa.identical, withoutAa.identical);
      assert.equal(withAa.nonidentical, withoutAa.nonidentical);
      assert.equal(withAa.aaLike, 4);
      assert.equal(withAaThresh.aaLike, 4);
      assert.equal(withAaThresh.overThreshold, noAaThresh.overThreshold);
      assert.equal(withAaThresh.nonidentical, noAaThresh.nonidentical);
    });
  });

  test("applies -i ignore regions and emits --output-diff-lines and --output-diff-cols", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 5, 5, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 5, 5, (x, y) => {
        if (x === 1 && y === 2) return BLACK;
        if (x === 3 && y === 4) return [240, 240, 240, 255];
        if (x === 4 && y === 1) return BLACK;
        return WHITE;
      });

      const allDiffs = await compare(a, b, ["--no-diff-image", "--output-diff-lines", "--output-diff-cols"]);
      assert.equal(allDiffs.identical, 22);
      assert.equal(allDiffs.nonidentical, 3);
      assert.deepEqual(allDiffs.diffLines, [1, 2, 4]);
      assert.deepEqual(allDiffs.diffCols, [1, 3, 4]);

      const withIgnore = compareSync(a, b, [
        "--no-diff-image",
        "-i",
        "1:2-2:3,0:0-0:0",
        "--output-diff-lines",
        "--output-diff-cols",
      ]);
      assert.equal(withIgnore.ignored, 5);
      assert.equal(withIgnore.ignoredDiff, 1);
      assert.equal(withIgnore.identical, 18);
      assert.equal(withIgnore.nonidentical, 2);
      assert.deepEqual(withIgnore.diffLines, [1, 4]);
      assert.deepEqual(withIgnore.diffCols, [3, 4]);

      const withThresh = await compare(a, b, [
        "--no-diff-image",
        "-i",
        "1:2-2:3",
        "-t",
        "0.2",
        "--output-diff-lines",
        "--output-diff-cols",
      ]);
      assert.equal(withThresh.ignored, 4);
      assert.equal(withThresh.ignoredDiff, 1);
      assert.equal(withThresh.nonidentical, 2);
      assert.equal(withThresh.overThreshold, 1);
      assert.deepEqual(withThresh.diffLines, [1]);
      assert.deepEqual(withThresh.diffCols, [4]);
    });
  });

  test("reports overhangBase, overhangBaseOpaque, overhangComp, and overhangCompOpaque on mismatched dimensions", async () => {
    await withTempDir(async (dir) => {
      const wide = writePng(path.join(dir, "wide.png"), 6, 4, (x, y) => {
        if (x >= 4) return y === 0 ? BLACK : [0, 0, 0, 0];
        return WHITE;
      });
      const tall = writePng(path.join(dir, "tall.png"), 4, 6, (x, y) => {
        if (y >= 4) return x < 2 ? [255, 0, 0, 128] : [255, 0, 0, 0];
        return WHITE;
      });
      const square = writePng(path.join(dir, "square.png"), 4, 4, () => WHITE);

      const twoSided = await compare(wide, tall, ["--no-diff-image"]);
      assert.deepEqual(twoSided.base, { w: 6, h: 4 });
      assert.deepEqual(twoSided.comp, { w: 4, h: 6 });
      assert.equal(twoSided.identical, 16);
      assert.equal(twoSided.nonidentical, 0);
      assert.equal(twoSided.overhangBase, 8);
      assert.equal(twoSided.overhangBaseOpaque, 2);
      assert.equal(twoSided.overhangComp, 8);
      assert.equal(twoSided.overhangCompOpaque, 4);

      const oneSided = compareSync(wide, square, ["--no-diff-image"]);
      assert.equal(oneSided.overhangBase, 8);
      assert.equal(oneSided.overhangBaseOpaque, 2);
      assert.equal(oneSided.overhangComp, undefined);
      assert.equal(oneSided.overhangCompOpaque, undefined);
    });
  });

  test("blends alpha onto #ffffff in delta-bin and thresholded comparisons", async () => {
    await withTempDir(async (dir) => {
      const opaqueWhite = writePng(path.join(dir, "white.png"), 2, 2, () => WHITE);
      const semiWhite = writePng(path.join(dir, "semi-white.png"), 2, 2, () => [255, 255, 255, 128]);
      const transparentRed = writePng(path.join(dir, "trans-red.png"), 2, 2, () => [255, 0, 0, 0]);
      const semiBlack = writePng(path.join(dir, "semi-black.png"), 2, 2, () => [0, 0, 0, 128]);
      const opaqueBlack = writePng(path.join(dir, "black.png"), 2, 2, () => BLACK);
      const midGray = writePng(path.join(dir, "gray.png"), 2, 2, () => [127, 127, 127, 255]);

      const semiWhiteZero = await compare(semiWhite, opaqueWhite, [
        "--no-diff-image",
        "-t",
        "0",
        "--delta-bin",
        path.join(dir, "sw.bin"),
      ]);
      assert.equal(semiWhiteZero.overThreshold, 0);
      assert.equal((await readDeltaBin(path.join(dir, "sw.bin"))).data[0], 0);

      const transRedZero = compareSync(transparentRed, opaqueWhite, [
        "--no-diff-image",
        "-t",
        "0",
        "--delta-bin",
        path.join(dir, "tr.bin"),
      ]);
      assert.equal(transRedZero.overThreshold, 0);
      assert.equal(readDeltaBinSync(path.join(dir, "tr.bin")).data[0], 0);

      const semiBlackVsWhite = await compare(semiBlack, opaqueWhite, [
        "--no-diff-image",
        "-t",
        "0.1",
        "--delta-bin",
        path.join(dir, "sbw.bin"),
      ]);
      assert.equal(semiBlackVsWhite.nonidentical, 4);
      assert.equal(semiBlackVsWhite.overThreshold, 4);
      const sbwDelta = readDeltaBinSync(path.join(dir, "sbw.bin")).data[0];
      assert.ok(sbwDelta > 0.35 && sbwDelta < 0.5, `expected blended semi-black vs white delta, got ${sbwDelta}`);

      const semiBlackVsBlack = await compare(semiBlack, opaqueBlack, [
        "--no-diff-image",
        "-t",
        "0.1",
        "--delta-bin",
        path.join(dir, "sbb.bin"),
      ]);
      assert.equal(semiBlackVsBlack.nonidentical, 4);
      assert.equal(semiBlackVsBlack.overThreshold, 4);
      const sbbDelta = readDeltaBinSync(path.join(dir, "sbb.bin")).data[0];
      assert.ok(sbbDelta > 0.5, `expected large delta vs opaque black, got ${sbbDelta}`);

      const semiBlackVsGray = await compare(semiBlack, midGray, [
        "--no-diff-image",
        "-t",
        "0",
        "--delta-bin",
        path.join(dir, "sg.bin"),
      ]);
      assert.equal(semiBlackVsGray.overThreshold, 0);
      assert.equal((await readDeltaBin(path.join(dir, "sg.bin"))).data[0], 0);
    });
  });

  test("treats pixels that blend identically onto #ffffff as identical in unthresholded counts", async () => {
    await withTempDir(async (dir) => {
      const opaqueWhite = writePng(path.join(dir, "white.png"), 2, 2, () => WHITE);
      const semiWhite = writePng(path.join(dir, "semi-white.png"), 2, 2, () => [255, 255, 255, 128]);
      const transparentRed = writePng(path.join(dir, "trans-red.png"), 2, 2, () => [255, 0, 0, 0]);

      const semiVsWhite = await compare(semiWhite, opaqueWhite, ["--no-diff-image"]);
      assert.equal(semiVsWhite.identical, 4);
      assert.equal(semiVsWhite.nonidentical, 0);

      const transRedVsWhite = compareSync(transparentRed, opaqueWhite, ["--no-diff-image"]);
      assert.equal(transRedVsWhite.identical, 4);
      assert.equal(transRedVsWhite.nonidentical, 0);
    });
  });
});

describe("render outputs and delta-bin", () => {
  test("renders default diff, --no-diff-image, --diff-mask, --diff-overlay, --diff-color, --aa-color, and --delta-map", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "diag1.png"), 10, 10, makeDiagBase(10));
      const b = writePng(path.join(dir, "diag2.png"), 10, 10, makeDiagComp(10));

      const skippedOut = path.join(dir, "skipped.png");
      await compare(a, b, [skippedOut, "--no-diff-image"]);
      assert.equal(existsSync(skippedOut), false);

      const defaultOut = path.join(dir, "default.png");
      await compare(a, b, [defaultOut]);
      const defaultImg = decodePngRgba(readFileSync(defaultOut));
      assert.deepEqual(pixelAt(defaultImg, 2, 3), [255, 0, 0, 255]);

      const maskOut = path.join(dir, "mask.png");
      await compare(a, b, [maskOut, "--diff-mask", "--diff-color", "#00ff00", "--aa", "--aa-color", "#ffff00"]);
      const maskImg = decodePngRgba(readFileSync(maskOut));
      assert.deepEqual(pixelAt(maskImg, 0, 0), [0, 0, 0, 0]);
      assert.deepEqual(pixelAt(maskImg, 2, 3), [255, 255, 0, 255]);
      assert.deepEqual(pixelAt(maskImg, 3, 2), [0, 255, 0, 255]);

      const overlayOut = path.join(dir, "overlay.png");
      compareSync(a, b, [overlayOut, "--diff-overlay", "0.5", "--diff-color", "#0000ff"]);
      const overlayImg = decodePngRgba(readFileSync(overlayOut));
      assert.deepEqual(pixelAt(overlayImg, 0, 0), [127, 127, 127, 255]);
      assert.deepEqual(pixelAt(overlayImg, 1, 0), [255, 255, 255, 255]);
      assert.deepEqual(pixelAt(overlayImg, 2, 3), [0, 0, 255, 255]);

      const deltaOut = path.join(dir, "delta-map.png");
      await compare(a, b, [deltaOut, "--delta-map=2.0", "-i", "0:0-0:0"]);
      const deltaImg = decodePngRgba(readFileSync(deltaOut));
      assert.deepEqual(pixelAt(deltaImg, 0, 0), [0, 0, 0, 0]);
      assert.deepEqual(pixelAt(deltaImg, 1, 0), [0, 0, 0, 255]);
      const diffPx = pixelAt(deltaImg, 2, 3);
      assert.equal(diffPx[0], diffPx[1]);
      assert.equal(diffPx[1], diffPx[2]);
      assert.ok(diffPx[0] > 0);
      assert.equal(diffPx[3], 255);

      const deltaDefaultOut = path.join(dir, "delta-map-default.png");
      compareSync(a, b, [deltaDefaultOut, "--delta-map"]);
      const deltaDefaultImg = decodePngRgba(readFileSync(deltaDefaultOut));
      const diffDefaultPx = pixelAt(deltaDefaultImg, 2, 3);
      assert.ok(diffDefaultPx[0] > 0 && diffDefaultPx[0] < diffPx[0]);
      assert.equal(diffDefaultPx[3], 255);
    });
  });

  test("writes and validates --delta-bin with 0, positive, and NaN entries across ignored and base overhang regions", async () => {
    await withTempDir(async (dir) => {
      const base = writePng(path.join(dir, "base.png"), 5, 3, (x, y) => (x >= 3 ? BLACK : WHITE));
      const comp = writePng(path.join(dir, "comp.png"), 3, 4, (x, y) => (x === 2 && y === 1 ? BLACK : WHITE));
      const binPath = path.join(dir, "out.delta");

      await compare(base, comp, ["--no-diff-image", "-i", "0:0-1:0", "--delta-bin", binPath]);

      const asyncBin = await readDeltaBin(binPath);
      const syncBin = readDeltaBinSync(binPath);
      assert.equal(asyncBin.width, 5);
      assert.equal(asyncBin.height, 3);
      assert.ok(asyncBin.data instanceof Float32Array);
      assert.equal(asyncBin.data.length, 15);
      assert.equal(syncBin.width, 5);
      assert.equal(syncBin.height, 3);
      assert.deepEqual(
        Array.from(syncBin.data, (v) => (Number.isNaN(v) ? "NaN" : v)),
        Array.from(asyncBin.data, (v) => (Number.isNaN(v) ? "NaN" : v)),
      );

      assert.ok(Number.isNaN(asyncBin.data[0]));
      assert.ok(Number.isNaN(asyncBin.data[1]));
      assert.equal(asyncBin.data[2], 0);
      assert.ok(Number.isNaN(asyncBin.data[3]));
      assert.ok(Number.isNaN(asyncBin.data[4]));

      assert.equal(asyncBin.data[5], 0);
      assert.equal(asyncBin.data[6], 0);
      assert.ok(Number.isFinite(asyncBin.data[7]) && asyncBin.data[7] > 0.9);
      assert.ok(Number.isNaN(asyncBin.data[8]));
      assert.ok(Number.isNaN(asyncBin.data[9]));

      assert.equal(asyncBin.data[10], 0);
      assert.equal(asyncBin.data[11], 0);
      assert.equal(asyncBin.data[12], 0);
      assert.ok(Number.isNaN(asyncBin.data[13]));
      assert.ok(Number.isNaN(asyncBin.data[14]));

      const emptyFile = path.join(dir, "empty.bin");
      const shortHdr = path.join(dir, "short.bin");
      const truncated = path.join(dir, "truncated.bin");
      const oversized = path.join(dir, "oversized.bin");

      writeFileSync(emptyFile, Buffer.alloc(0));
      writeFileSync(shortHdr, Buffer.alloc(4));
      const truncBuf = Buffer.alloc(12);
      truncBuf.writeUInt32LE(2, 0);
      truncBuf.writeUInt32LE(2, 4);
      writeFileSync(truncated, truncBuf);
      const overBuf = Buffer.alloc(8 + 2 * 2 * 4 + 4);
      overBuf.writeUInt32LE(2, 0);
      overBuf.writeUInt32LE(2, 4);
      writeFileSync(oversized, overBuf);

      for (const badPath of [emptyFile, shortHdr, truncated, oversized]) {
        assert.throws(() => readDeltaBinSync(badPath), OkdiffError);
        await assert.rejects(() => readDeltaBin(badPath), OkdiffError);
      }
    });
  });
});

describe("compareDir", () => {
  test("processes multiple stems, diff-dir, delta-bin dir, line/col flags, -j 1, onlyInA/onlyInB, and corrupt PNG errors", async () => {
    await withTempDir(async (dir) => {
      const dirA = path.join(dir, "a");
      const dirB = path.join(dir, "b");
      const diffDir = path.join(dir, "diffs");
      const deltaDir = path.join(dir, "deltas");
      mkdirSync(dirA);
      mkdirSync(dirB);

      writePng(path.join(dirA, "same.png"), 2, 2, () => WHITE);
      writePng(path.join(dirB, "same.png"), 2, 2, () => WHITE);

      writePng(path.join(dirA, "diff.png"), 2, 2, () => WHITE);
      writePng(path.join(dirB, "diff.png"), 2, 2, (x, y) => (x === 1 && y === 0 ? BLACK : WHITE));

      writePng(path.join(dirA, "multi.png"), 2, 2, () => WHITE);
      writePng(path.join(dirB, "multi.png"), 2, 2, (_x, y) => (y === 1 ? BLACK : WHITE));

      writeFileSync(path.join(dirA, "broken.png"), Buffer.from("not-a-valid-png"));
      writeFileSync(path.join(dirB, "broken.png"), Buffer.from("not-a-valid-png"));

      writePng(path.join(dirA, "only_a.png"), 2, 2, () => BLACK);
      writePng(path.join(dirB, "only_b.png"), 2, 2, () => BLACK);

      const report = await compareDir(dirA, dirB, [
        "--diff-dir",
        diffDir,
        "--delta-bin",
        deltaDir,
        "--output-diff-lines",
        "--output-diff-cols",
        "-j",
        "1",
      ]);

      assert.deepEqual(report.onlyInA, ["only_a"]);
      assert.deepEqual(report.onlyInB, ["only_b"]);
      assert.equal(report.pairs.length, 4);

      const byStem = new Map<string, DiffReport>(report.pairs.map((p) => [p.stem ?? "", p]));

      const same = byStem.get("same");
      assert.ok(same);
      assert.equal(same.identical, 4);
      assert.equal(same.nonidentical, 0);
      assert.equal(same.error, undefined);

      const multi = byStem.get("multi");
      assert.ok(multi);
      assert.equal(multi.identical, 2);
      assert.equal(multi.nonidentical, 2);
      assert.deepEqual(multi.diffLines, [1]);
      assert.deepEqual(multi.diffCols, [0, 1]);
      assert.equal(multi.error, undefined);

      const diff = byStem.get("diff");
      assert.ok(diff);
      assert.equal(diff.identical, 3);
      assert.equal(diff.nonidentical, 1);
      assert.deepEqual(diff.diffLines, [0]);
      assert.deepEqual(diff.diffCols, [1]);
      assert.equal(diff.error, undefined);

      const broken = byStem.get("broken");
      assert.ok(broken);
      assert.equal(typeof broken.error, "string");
      assert.ok((broken.error ?? "").length > 0);

      for (const stem of ["same", "diff", "multi"]) {
        assert.ok(existsSync(path.join(diffDir, `${stem}.png`)));
        assert.ok(existsSync(path.join(deltaDir, `${stem}.delta`)));
      }
      assert.equal(existsSync(path.join(diffDir, "broken.png")), false);

      const diffDelta = await readDeltaBin(path.join(deltaDir, "diff.delta"));
      assert.equal(diffDelta.width, 2);
      assert.equal(diffDelta.height, 2);
      assert.equal(diffDelta.data[0], 0);
      assert.ok(diffDelta.data[1] > 0.9);
    });
  });
});

describe("OkdiffServer", () => {
  test("correlates concurrent Promise.all requests and supports all ServerRequest rendering and measurement options", async () => {
    await withTempDir(async (dir) => {
      const d1 = writePng(path.join(dir, "d1.png"), 10, 10, makeDiagBase(10));
      const d2 = writePng(path.join(dir, "d2.png"), 10, 10, makeDiagComp(10));

      const pairs: Array<{ base: string; comp: string; w: number; h: number; nonid: number }> = [];
      for (let i = 0; i < 8; i++) {
        const w = 4 + (i % 3);
        const h = 4 + ((i + 1) % 3);
        const diffCount = i + 1;
        const a = writePng(path.join(dir, `p${i}a.png`), w, h, () => WHITE);
        const b = writePng(path.join(dir, `p${i}b.png`), w, h, (x, y) =>
          y * w + x < diffCount ? BLACK : WHITE,
        );
        pairs.push({ base: a, comp: b, w, h, nonid: diffCount });
      }

      const server = new OkdiffServer();
      try {
        const results = await Promise.all(
          pairs.map((p) => server.compare({ base: p.base, comp: p.comp })),
        );
        const ids = new Set<number>();
        for (let i = 0; i < pairs.length; i++) {
          const r = results[i];
          const expected = pairs[i];
          assert.equal(typeof r.requestId, "number");
          ids.add(r.requestId!);
          assert.deepEqual(r.base, { w: expected.w, h: expected.h });
          assert.deepEqual(r.comp, { w: expected.w, h: expected.h });
          assert.equal(r.nonidentical, expected.nonid);
          assert.equal(r.identical, expected.w * expected.h - expected.nonid);
        }
        assert.equal(ids.size, pairs.length);

        const maskPath = path.join(dir, "srv-mask.png");
        const deltaBinPath = path.join(dir, "srv-out.delta");
        const maskRes = await server.compare({
          base: d1,
          comp: d2,
          diff: maskPath,
          diffMask: true,
          diffColor: "#00ff00",
          aaColor: "#ffff00",
          antialiasing: true,
          deltaBin: deltaBinPath,
          ignoreRegions: [{ x1: 0, y1: 0, x2: 1, y2: 1 }],
          diffLines: true,
          diffCols: true,
        });
        assert.equal(maskRes.ignored, 4);
        assert.equal(maskRes.ignoredDiff, 0);
        assert.equal(maskRes.aaLike, 4);
        assert.equal(maskRes.nonidentical, 12);
        assert.ok(Array.isArray(maskRes.diffLines) && maskRes.diffLines.length > 0);
        assert.ok(Array.isArray(maskRes.diffCols) && maskRes.diffCols.length > 0);

        const maskImg = decodePngRgba(readFileSync(maskPath));
        assert.deepEqual(pixelAt(maskImg, 0, 0), [0, 0, 0, 0]);
        assert.deepEqual(pixelAt(maskImg, 2, 3), [255, 255, 0, 255]);
        assert.deepEqual(pixelAt(maskImg, 3, 2), [0, 255, 0, 255]);

        const deltaBin = await readDeltaBin(deltaBinPath);
        assert.equal(deltaBin.width, 10);
        assert.equal(deltaBin.height, 10);
        assert.ok(Number.isNaN(deltaBin.data[0]));
        assert.ok(Number.isNaN(deltaBin.data[11]));
        assert.ok(deltaBin.data[3 * 10 + 2] > 0);

        const overlayPath = path.join(dir, "srv-overlay.png");
        const overlayRes = await server.compare({
          base: d1,
          comp: d2,
          diff: overlayPath,
          diffOverlay: 0.5,
          diffColor: "#0000ff",
          metric: "yiq",
          threshold: 0.1,
        });
        assert.equal(overlayRes.threshold, 0.1);
        assert.equal(overlayRes.overThreshold, 12);
        const overlayImg = decodePngRgba(readFileSync(overlayPath));
        assert.deepEqual(pixelAt(overlayImg, 0, 0), [127, 127, 127, 255]);
        assert.deepEqual(pixelAt(overlayImg, 2, 3), [0, 0, 255, 255]);

        const deltaMapPath = path.join(dir, "srv-deltamap.png");
        await server.compare({
          base: d1,
          comp: d2,
          diff: deltaMapPath,
          deltaMap: 2.0,
          ignoreRegions: [{ x1: 0, y1: 0, x2: 0, y2: 0 }],
        });
        const deltaMapImg = decodePngRgba(readFileSync(deltaMapPath));
        assert.deepEqual(pixelAt(deltaMapImg, 0, 0), [0, 0, 0, 0]);
        assert.deepEqual(pixelAt(deltaMapImg, 1, 0), [0, 0, 0, 255]);
        assert.ok(pixelAt(deltaMapImg, 2, 3)[0] > 0);
      } finally {
        await server.close();
      }
    });
  });

  test("recovers cleanly after per-request errors and rejects after close()", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 2, 2, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 2, 2, (x, y) => (x === 0 && y === 0 ? BLACK : WHITE));
      const server = new OkdiffServer();

      await assert.rejects(
        () => server.compare({ base: path.join(dir, "missing.png"), comp: b }),
        (err: unknown) => err instanceof OkdiffError && err.message.length > 0,
      );
      await assert.rejects(
        () => server.compare({ base: a, comp: b, metric: "unknown_metric" } as unknown as ServerRequest),
        (err: unknown) => err instanceof OkdiffError && err.message.length > 0,
      );
      await assert.rejects(
        () => server.compare({ base: a, comp: b, threshold: -1 }),
        (err: unknown) => err instanceof OkdiffError && err.message.length > 0,
      );

      const healthy = await server.compare({ base: a, comp: b });
      assert.equal(healthy.identical, 3);
      assert.equal(healthy.nonidentical, 1);

      await server.close();
      await server.close();

      await assert.rejects(
        () => server.compare({ base: a, comp: b }),
        (err: unknown) => err instanceof OkdiffError && err.message.includes("closed"),
      );
    });
  });

  test("supports await using and explicit [Symbol.asyncDispose]()", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 2, 2, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 2, 2, () => BLACK);

      let leakedServer: OkdiffServer;
      {
        await using server = new OkdiffServer();
        leakedServer = server;
        const res = await server.compare({ base: a, comp: b });
        assert.equal(res.nonidentical, 4);
      }

      await assert.rejects(
        () => leakedServer.compare({ base: a, comp: b }),
        (err: unknown) => err instanceof OkdiffError && err.message.includes("closed"),
      );

      const manual = new OkdiffServer();
      const ok = await manual.compare({ base: a, comp: b });
      assert.equal(ok.nonidentical, 4);
      await manual[Symbol.asyncDispose]();
      await assert.rejects(
        () => manual.compare({ base: a, comp: b }),
        (err: unknown) => err instanceof OkdiffError && err.message.includes("closed"),
      );
    });
  });
});

describe("error contracts", () => {
  test("throws OkdiffError with exitCode 2 on missing files, bad PNGs, and invalid CLI arguments", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 2, 2, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 2, 2, () => BLACK);
      const corrupt = path.join(dir, "corrupt.png");
      writeFileSync(corrupt, Buffer.from("corrupt-png-bytes"));
      const missing = path.join(dir, "does-not-exist.png");

      const badCases: Array<[string, string, string[]]> = [
        [missing, b, ["--no-diff-image"]],
        [a, corrupt, ["--no-diff-image"]],
        [a, b, ["--no-diff-image", "--metric", "invalid"]],
        [a, b, ["--no-diff-image", "-t", "-0.5"]],
        [a, b, ["--no-diff-image", "-i", "3:3-1:1"]],
        [a, b, ["--no-diff-image", "--no-such-flag"]],
      ];

      for (const [base, comp, args] of badCases) {
        assert.throws(
          () => compareSync(base, comp, args),
          (err: unknown) => err instanceof OkdiffError && err.name === "OkdiffError" && err.exitCode === 2,
        );
        await assert.rejects(
          () => compare(base, comp, args),
          (err: unknown) => err instanceof OkdiffError && err.name === "OkdiffError" && err.exitCode === 2,
        );
      }
    });
  });

  test("throws OkdiffError with null exitCode when binary cannot be launched", async () => {
    await withTempDir(async (dir) => {
      const a = writePng(path.join(dir, "a.png"), 2, 2, () => WHITE);
      const b = writePng(path.join(dir, "b.png"), 2, 2, () => BLACK);
      const missingBin = path.join(dir, "nonexistent-okdiff-binary");

      assert.throws(
        () => compareSync(a, b, ["--no-diff-image"], missingBin),
        (err: unknown) =>
          err instanceof OkdiffError && err.exitCode === null && err.message.includes("failed to launch"),
      );
      await assert.rejects(
        () => compare(a, b, ["--no-diff-image"], missingBin),
        (err: unknown) =>
          err instanceof OkdiffError && err.exitCode === null && err.message.includes("failed to launch"),
      );
    });
  });
});
