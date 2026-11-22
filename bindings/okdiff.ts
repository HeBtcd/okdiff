import { spawn, spawnSync, type ChildProcessByStdio } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import type { Readable, Writable } from "node:stream";
import { fileURLToPath } from "node:url";

export interface Dimensions { w: number; h: number; }
export interface Region { x1: number; y1: number; x2: number; y2: number; }

export interface DiffReport {
  stem?: string;
  requestId?: number;
  base: Dimensions;
  comp: Dimensions;
  identical: number;
  nonidentical: number;
  ignored?: number;
  ignoredDiff?: number;
  threshold?: number;
  overThreshold?: number;
  aaLike?: number;
  overhangBase?: number;
  overhangBaseOpaque?: number;
  overhangComp?: number;
  overhangCompOpaque?: number;
  diffLines?: number[];
  diffCols?: number[];
  error?: string;
}

export interface DirReport {
  pairs: DiffReport[];
  onlyInA?: string[];
  onlyInB?: string[];
}

export interface DeltaBin { width: number; height: number; data: Float32Array; }

export interface ServerRequest {
  base: string;
  comp: string;
  diff?: string;
  threshold?: number;
  metric?: "oklab" | "yiq";
  antialiasing?: boolean;
  diffLines?: boolean;
  diffCols?: boolean;
  diffMask?: boolean;
  diffOverlay?: number;
  diffColor?: string;
  aaColor?: string;
  deltaMap?: number;
  deltaBin?: string;
  ignoreRegions?: Region[];
}

export class OkdiffError extends Error {
  readonly exitCode: number | null;
  constructor(message: string, exitCode: number | null = null) {
    super(message);
    this.name = "OkdiffError";
    this.exitCode = exitCode;
  }
}

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const EXE = process.platform === "win32" ? "okdiff.exe" : "okdiff";

export function resolveBinary(binary?: string): string {
  if (binary) return binary;
  if (process.env.OKDIFF_BIN) return process.env.OKDIFF_BIN;
  for (const c of [path.resolve(MODULE_DIR, "../zig-out/bin", EXE), path.resolve(process.cwd(), "zig-out/bin", EXE)]) {
    if (existsSync(c)) return c;
  }
  return EXE;
}

function withJson(args: readonly string[]): string[] {
  return args.includes("--json") ? [...args] : [...args, "--json"];
}

function parseJson<T>(stdout: string, stderr: string, code: number | null, bin: string): T {
  if (code !== 0) throw new OkdiffError(`${bin}: ${(stderr || stdout).trim() || `exit code ${code}`}`, code);
  try {
    return JSON.parse(stdout) as T;
  } catch (e) {
    throw new OkdiffError(`failed to parse okdiff JSON: ${(e as Error).message}; raw=${stdout.trim()}`, code);
  }
}

function execAsync<T>(bin: string, args: readonly string[]): Promise<T> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (d: string) => { out += d; });
    child.stderr.on("data", (d: string) => { err += d; });
    child.on("error", (e) => reject(new OkdiffError(`failed to launch '${bin}': ${e.message}`)));
    child.on("close", (code) => {
      try { resolve(parseJson<T>(out, err, code, bin)); } catch (e) { reject(e); }
    });
  });
}

export const compare = (base: string, comp: string, args: readonly string[] = [], binary?: string): Promise<DiffReport> =>
  execAsync<DiffReport>(resolveBinary(binary), withJson([base, comp, ...args]));

export function compareSync(base: string, comp: string, args: readonly string[] = [], binary?: string): DiffReport {
  const bin = resolveBinary(binary);
  const res = spawnSync(bin, withJson([base, comp, ...args]), { encoding: "utf8" });
  if (res.error) throw new OkdiffError(`failed to launch '${bin}': ${res.error.message}`);
  return parseJson<DiffReport>(res.stdout ?? "", res.stderr ?? "", res.status, bin);
}

export const compareDir = (dirA: string, dirB: string, args: readonly string[] = [], binary?: string): Promise<DirReport> =>
  execAsync<DirReport>(resolveBinary(binary), withJson([dirA, dirB, ...args]));

function decodeDeltaBin(buf: Buffer): DeltaBin {
  if (buf.byteLength < 8) throw new OkdiffError(`invalid delta binary: ${buf.byteLength} bytes`);
  const width = buf.readUInt32LE(0), height = buf.readUInt32LE(4), expected = 8 + width * height * 4;
  if (buf.byteLength !== expected) throw new OkdiffError(`expected ${expected} bytes for ${width}x${height}, got ${buf.byteLength}`);
  const data = new Float32Array(width * height);
  for (let i = 0; i < data.length; i++) data[i] = buf.readFloatLE(8 + i * 4);
  return { width, height, data };
}

export const readDeltaBin = async (filePath: string): Promise<DeltaBin> => decodeDeltaBin(await readFile(filePath));
export const readDeltaBinSync = (filePath: string): DeltaBin => decodeDeltaBin(readFileSync(filePath));

export class OkdiffServer {
  readonly #child: ChildProcessByStdio<Writable, Readable, Readable>;
  readonly #pending = new Map<number, { resolve: (v: DiffReport) => void; reject: (e: Error) => void }>();
  #nextId = 1;
  #buf = "";
  #err = "";
  #closed = false;

  constructor(args: readonly string[] = [], binary?: string) {
    const bin = resolveBinary(binary);
    this.#child = spawn(bin, ["--server", ...args], { stdio: ["pipe", "pipe", "pipe"] });
    this.#child.stdout.setEncoding("utf8");
    this.#child.stderr.setEncoding("utf8");
    const fail = (err: Error) => {
      this.#closed = true;
      this.#pending.forEach((p) => p.reject(err));
      this.#pending.clear();
    };
    this.#child.stderr.on("data", (d: string) => { this.#err += d; });
    this.#child.stdin.on("error", (e) => fail(new OkdiffError(`okdiff server stdin failed: ${e.message}`)));
    this.#child.stdout.on("data", (d: string) => {
      this.#buf += d;
      for (let nl = this.#buf.indexOf("\n"); nl !== -1; nl = this.#buf.indexOf("\n")) {
        const line = this.#buf.slice(0, nl).trim();
        this.#buf = this.#buf.slice(nl + 1);
        if (!line) continue;
        let msg: DiffReport;
        try {
          msg = JSON.parse(line) as DiffReport;
        } catch (e) {
          fail(new OkdiffError(`malformed okdiff server JSON: ${(e as Error).message}; raw=${line}`));
          return;
        }
        const entry = msg.requestId !== undefined ? this.#pending.get(msg.requestId) : undefined;
        if (!entry) {
          if (msg.error && this.#pending.size === 1) {
            const firstKey = this.#pending.keys().next().value!;
            const sole = this.#pending.get(firstKey)!;
            this.#pending.delete(firstKey);
            sole.reject(new OkdiffError(msg.error));
          }
          continue;
        }
        this.#pending.delete(msg.requestId!);
        if (msg.error) entry.reject(new OkdiffError(msg.error));
        else entry.resolve(msg);
      }
    });
    this.#child.on("error", (e) => fail(new OkdiffError(`okdiff server failed: ${e.message}`)));
    this.#child.on("close", (code) => {
      this.#closed = true;
      if (this.#pending.size) fail(new OkdiffError(this.#err.trim() || `okdiff server exited (${code})`, code));
    });
  }

  compare(req: ServerRequest): Promise<DiffReport> {
    if (this.#closed || this.#child.exitCode !== null) return Promise.reject(new OkdiffError("okdiff server is closed"));
    const requestId = this.#nextId++;
    return new Promise((resolve, reject) => {
      this.#pending.set(requestId, { resolve, reject });
      this.#child.stdin.write(`${JSON.stringify({ ...req, requestId })}\n`);
    });
  }

  close(): Promise<void> {
    if (this.#closed) return Promise.resolve();
    this.#closed = true;
    return new Promise((resolve) => {
      if (this.#child.exitCode !== null || this.#child.killed) return resolve();
      this.#child.once("close", () => resolve());
      try {
        this.#child.stdin.write('{"command":"close"}\n');
        this.#child.stdin.end();
      } catch {
        this.#child.kill();
      }
    });
  }

  [Symbol.asyncDispose](): Promise<void> { return this.close(); }
}
