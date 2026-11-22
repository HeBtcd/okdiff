from __future__ import annotations

from array import array
from dataclasses import dataclass
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
from typing import Any, Literal, Mapping, Sequence, TypedDict

PathLike = str | os.PathLike[str]

__all__ = [
    "DeltaBin", "DiffReport", "Dimensions", "DirReport", "OkdiffError",
    "OkdiffServer", "Region", "ServerRequest", "compare", "compare_dir",
    "read_delta_bin", "resolve_binary",
]

_EXE = "okdiff.exe" if sys.platform == "win32" else "okdiff"
_MODULE_DIR = Path(__file__).resolve().parent


class Dimensions(TypedDict):
    w: int
    h: int


class Region(TypedDict):
    x1: int
    y1: int
    x2: int
    y2: int


class _DiffReportBase(TypedDict):
    base: Dimensions
    comp: Dimensions
    identical: int
    nonidentical: int


class DiffReport(_DiffReportBase, total=False):
    stem: str
    requestId: int
    ignored: int
    ignoredDiff: int
    threshold: float
    overThreshold: int
    aaLike: int
    overhangBase: int
    overhangBaseOpaque: int
    overhangComp: int
    overhangCompOpaque: int
    diffLines: list[int]
    diffCols: list[int]
    error: str


class _DirReportBase(TypedDict):
    pairs: list[DiffReport]


class DirReport(_DirReportBase, total=False):
    onlyInA: list[str]
    onlyInB: list[str]


class _ServerRequestBase(TypedDict):
    base: str
    comp: str


class ServerRequest(_ServerRequestBase, total=False):
    diff: str
    threshold: float
    metric: Literal["oklab", "yiq"]
    antialiasing: bool
    diffLines: bool
    diffCols: bool
    diffMask: bool
    diffOverlay: float
    diffColor: str
    aaColor: str
    deltaMap: float
    deltaBin: str
    ignoreRegions: list[Region]


class OkdiffError(RuntimeError):
    def __init__(self, message: str, exit_code: int | None = None) -> None:
        super().__init__(message)
        self.exit_code = exit_code


@dataclass(frozen=True, slots=True)
class DeltaBin:
    width: int
    height: int
    values: array

    def at(self, x: int, y: int) -> float:
        if not (0 <= x < self.width and 0 <= y < self.height):
            raise IndexError(f"coordinate ({x}, {y}) outside {self.width}x{self.height}")
        return float(self.values[y * self.width + x])


def resolve_binary(binary: PathLike | None = None) -> str:
    if binary is not None:
        return os.fspath(binary)
    if env_bin := os.environ.get("OKDIFF_BIN"):
        return env_bin
    for cand in (_MODULE_DIR.parent / "zig-out" / "bin" / _EXE, Path.cwd() / "zig-out" / "bin" / _EXE):
        if cand.is_file():
            return str(cand)
    return _EXE


def _run_json(cmd: list[str]) -> Any:
    if "--json" not in cmd:
        cmd.append("--json")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", check=False)
    except OSError as exc:
        raise OkdiffError(f"failed to launch '{cmd[0]}': {exc}") from exc
    if proc.returncode != 0:
        raise OkdiffError(f"{cmd[0]}: {(proc.stderr or proc.stdout).strip() or f'exit {proc.returncode}'}", proc.returncode)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise OkdiffError(f"failed to parse okdiff JSON: {exc}; raw={proc.stdout.strip()}", proc.returncode) from exc


def compare(base: PathLike, comp: PathLike, args: Sequence[str] = (), *, binary: PathLike | None = None) -> DiffReport:
    return _run_json([resolve_binary(binary), os.fspath(base), os.fspath(comp), *args])


def compare_dir(dir_a: PathLike, dir_b: PathLike, args: Sequence[str] = (), *, binary: PathLike | None = None) -> DirReport:
    return _run_json([resolve_binary(binary), os.fspath(dir_a), os.fspath(dir_b), *args])


def read_delta_bin(path: PathLike) -> DeltaBin:
    raw = Path(path).read_bytes()
    if len(raw) < 8:
        raise OkdiffError(f"invalid delta binary: {len(raw)} bytes")
    w, h = struct.unpack_from("<II", raw, 0)
    expected = 8 + w * h * 4
    if len(raw) != expected:
        raise OkdiffError(f"expected {expected} bytes for {w}x{h}, got {len(raw)}")
    values = array("f")
    values.frombytes(raw[8:])
    if sys.byteorder != "little":
        values.byteswap()
    return DeltaBin(width=w, height=h, values=values)


class OkdiffServer:
    def __init__(self, args: Sequence[str] = (), *, binary: PathLike | None = None) -> None:
        bin_path = resolve_binary(binary)
        try:
            self._proc = subprocess.Popen(
                [bin_path, "--server", *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1,
            )
        except OSError as exc:
            raise OkdiffError(f"failed to launch '{bin_path}': {exc}") from exc
        self._next_id = 1
        self._closed = False

    def compare(self, req: Mapping[str, Any]) -> DiffReport:
        if self._closed or self._proc.poll() is not None or self._proc.stdin is None or self._proc.stdout is None:
            raise OkdiffError("okdiff server is closed")
        req_id = self._next_id
        self._next_id += 1
        wire = {**req, "requestId": req_id}
        try:
            self._proc.stdin.write(json.dumps(wire) + "\n")
            self._proc.stdin.flush()
        except OSError as exc:
            detail = self._proc.stderr.read().strip() if self._proc.stderr else ""
            raise OkdiffError(detail or f"okdiff server write failed: {exc}", self._proc.poll()) from exc
        line = self._proc.stdout.readline()
        if not line:
            detail = self._proc.stderr.read().strip() if self._proc.stderr else ""
            code = self._proc.poll()
            raise OkdiffError(detail or f"okdiff server exited ({code})", code)
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exc:
            raise OkdiffError(f"malformed okdiff server JSON: {exc}; raw={line.strip()}") from exc
        if "error" in payload:
            raise OkdiffError(str(payload["error"]))
        return payload

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._proc.stdin is not None and not self._proc.stdin.closed:
            try:
                self._proc.stdin.write('{"command":"close"}\n')
                self._proc.stdin.flush()
                self._proc.stdin.close()
            except OSError:
                pass
        for stream in (self._proc.stdout, self._proc.stderr):
            if stream is not None and not stream.closed:
                stream.close()
        try:
            self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait()

    def __enter__(self) -> OkdiffServer:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
