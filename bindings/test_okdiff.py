import ast
import math
from pathlib import Path
import struct
import sys
import zlib

import pytest

import okdiff


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def _make_png(
    path: Path,
    width: int,
    height: int,
    pixels: list[tuple[int, ...]],
    color_type: int = 6,
) -> Path:
    if len(pixels) != width * height:
        raise ValueError("pixel count mismatch")
    if color_type == 6:
        fmt = "BBBB"
    elif color_type == 2:
        fmt = "BBB"
    else:
        raise ValueError(f"unsupported color_type {color_type}")
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            px = pixels[y * width + x]
            row.extend(struct.pack(fmt, *px[: len(fmt)]))
        rows.append(bytes(row))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    idat = zlib.compress(b"".join(rows))
    data = (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", idat)
        + _png_chunk(b"IEND", b"")
    )
    path.write_bytes(data)
    return path


def _read_png(path: Path) -> tuple[int, int, list[list[tuple[int, int, int, int]]]]:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    idat = bytearray()
    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    while pos < len(data):
        length, tag = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.extend(body)
        elif tag == b"IEND":
            break
    assert bit_depth == 8
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    raw = zlib.decompress(bytes(idat))
    stride = width * bpp
    prev = bytes(stride)
    rows: list[list[tuple[int, int, int, int]]] = []
    for y in range(height):
        start = y * (stride + 1)
        filt = raw[start]
        row = bytearray(raw[start + 1 : start + 1 + stride])
        if filt == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif filt == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filt == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa = abs(b - c)
                pb = abs(a - c)
                pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 0xFF
        prev = bytes(row)
        out_row: list[tuple[int, int, int, int]] = []
        for x in range(width):
            off = x * bpp
            if color_type == 6:
                out_row.append((row[off], row[off + 1], row[off + 2], row[off + 3]))
            elif color_type == 2:
                out_row.append((row[off], row[off + 1], row[off + 2], 255))
            elif color_type == 4:
                out_row.append((row[off], row[off], row[off], row[off + 1]))
            else:
                out_row.append((row[off], row[off], row[off], 255))
        rows.append(out_row)
    return width, height, rows


def _make_aa_pair(tmp_path: Path, stem: str = "aa") -> tuple[Path, Path]:
    w, h = 8, 8
    base_px = [(255, 255, 255, 255)] * (w * h)
    for y in range(h):
        for x in range(w):
            if x < y:
                base_px[y * w + x] = (0, 0, 0, 255)
    comp_px = list(base_px)
    for y in range(1, h - 1):
        comp_px[y * w + y] = (128, 128, 128, 255)
    comp_px[1 * w + 6] = (0, 0, 255, 255)
    a = _make_png(tmp_path / f"{stem}_a.png", w, h, base_px)
    b = _make_png(tmp_path / f"{stem}_b.png", w, h, comp_px)
    return a, b


def test_python_310_ast_and_exports() -> None:
    module_path = Path(okdiff.__file__).resolve()
    source = module_path.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(module_path), feature_version=(3, 10))
    disallowed = {"NotRequired", "Required"}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            imported = {alias.name for alias in node.names}
            assert not (imported & disallowed)
        elif isinstance(node, ast.Name):
            assert node.id not in disallowed
        elif isinstance(node, ast.Attribute):
            assert node.attr not in disallowed

    expected_exports = {
        "DeltaBin",
        "DiffReport",
        "Dimensions",
        "DirReport",
        "OkdiffError",
        "OkdiffServer",
        "Region",
        "ServerRequest",
        "compare",
        "compare_dir",
        "read_delta_bin",
        "resolve_binary",
    }
    assert isinstance(okdiff.__all__, list)
    assert set(okdiff.__all__) == expected_exports
    for name in okdiff.__all__:
        assert hasattr(okdiff, name)


def test_resolve_binary(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    explicit_path = tmp_path / "custom_okdiff.exe"
    env_path = tmp_path / "env_okdiff.exe"
    monkeypatch.setenv("OKDIFF_BIN", str(env_path))

    assert okdiff.resolve_binary(explicit_path) == str(explicit_path)
    assert okdiff.resolve_binary(str(explicit_path)) == str(explicit_path)
    assert okdiff.resolve_binary() == str(env_path)

    monkeypatch.delenv("OKDIFF_BIN", raising=False)
    resolved = Path(okdiff.resolve_binary())
    exe_name = "okdiff.exe" if sys.platform == "win32" else "okdiff"
    expected_repo_bin = Path(__file__).resolve().parent.parent / "zig-out" / "bin" / exe_name
    assert resolved == expected_repo_bin
    assert resolved.is_file()


def test_compare_path_and_str_identical_and_differing(tmp_path: Path) -> None:
    w, h = 4, 4
    white = [(255, 255, 255, 255)] * (w * h)
    diff_px = list(white)
    diff_px[0] = (255, 0, 0, 255)

    a = _make_png(tmp_path / "a.png", w, h, white)
    a_copy = _make_png(tmp_path / "a_copy.png", w, h, white)
    a_rgb = _make_png(tmp_path / "a_rgb.png", w, h, white, color_type=2)
    b = _make_png(tmp_path / "b.png", w, h, diff_px)

    rep_path = okdiff.compare(a, a_copy)
    assert rep_path["base"] == {"w": 4, "h": 4}
    assert rep_path["comp"] == {"w": 4, "h": 4}
    assert rep_path["identical"] == 16
    assert rep_path["nonidentical"] == 0
    for absent in (
        "overThreshold",
        "aaLike",
        "diffLines",
        "diffCols",
        "ignored",
        "overhangBase",
        "overhangComp",
        "error",
    ):
        assert absent not in rep_path

    rep_rgb = okdiff.compare(str(a), str(a_rgb))
    assert rep_rgb["identical"] == 16
    assert rep_rgb["nonidentical"] == 0

    rep_diff_str = okdiff.compare(str(a), str(b))
    rep_diff_path = okdiff.compare(a, b)
    assert rep_diff_str["identical"] == 15
    assert rep_diff_str["nonidentical"] == 1
    assert rep_diff_path["identical"] == 15
    assert rep_diff_path["nonidentical"] == 1


def test_compare_metrics_and_threshold(tmp_path: Path) -> None:
    a = _make_png(
        tmp_path / "a.png",
        4,
        1,
        [(255, 255, 255, 255)] * 4,
    )
    b = _make_png(
        tmp_path / "b.png",
        4,
        1,
        [
            (128, 128, 128, 255),
            (0, 0, 0, 255),
            (240, 240, 240, 255),
            (255, 255, 255, 255),
        ],
    )

    ok_bin = tmp_path / "ok.delta"
    yiq_bin = tmp_path / "yiq.delta"
    rep_ok = okdiff.compare(
        a, b, ["--metric", "oklab", "-t", "0.45", "--delta-bin", str(ok_bin)]
    )
    rep_yiq = okdiff.compare(
        a, b, ["--metric", "yiq", "-t", "0.45", "--delta-bin", str(yiq_bin)]
    )

    assert rep_ok["identical"] == 1
    assert rep_ok["nonidentical"] == 3
    assert rep_ok["threshold"] == pytest.approx(0.45)
    assert rep_ok["overThreshold"] == 1

    assert rep_yiq["identical"] == 1
    assert rep_yiq["nonidentical"] == 3
    assert rep_yiq["threshold"] == pytest.approx(0.45)
    assert rep_yiq["overThreshold"] == 2

    db_ok = okdiff.read_delta_bin(ok_bin)
    db_yiq = okdiff.read_delta_bin(yiq_bin)
    assert all(0.0 <= v <= 1.0 for v in db_ok.values)
    assert all(0.0 <= v <= 1.0 for v in db_yiq.values)
    assert 0.35 < db_ok.at(0, 0) < 0.45
    assert db_ok.at(1, 0) == pytest.approx(1.0, abs=1e-4)
    assert 0.0 < db_ok.at(2, 0) < 0.1
    assert db_ok.at(3, 0) == 0.0
    assert 0.45 < db_yiq.at(0, 0) < 0.55
    assert 0.90 < db_yiq.at(1, 0) <= 1.0
    assert 0.0 < db_yiq.at(2, 0) < 0.1
    assert db_yiq.at(3, 0) == 0.0
    assert sum(1 for v in db_ok.values if v > 0.45) == rep_ok["overThreshold"]
    assert sum(1 for v in db_yiq.values if v > 0.45) == rep_yiq["overThreshold"]

    rep_low_t = okdiff.compare(a, b, ["-t", "0.2"])
    assert rep_low_t["nonidentical"] == 3
    assert rep_low_t["overThreshold"] == 2


def test_compare_aa_and_colors(tmp_path: Path) -> None:
    a, b = _make_aa_pair(tmp_path)
    out_png = tmp_path / "aa_diff.png"
    rep = okdiff.compare(
        a,
        b,
        [str(out_png), "--aa", "--aa-color", "\x23ffff00", "--diff-color", "\x23ff00ff"],
    )
    assert rep["identical"] == 57
    assert rep["nonidentical"] == 7
    assert rep["aaLike"] == 6

    rep_thresh = okdiff.compare(a, b, ["--aa", "-t", "0.1"])
    assert rep_thresh["nonidentical"] == 7
    assert rep_thresh["overThreshold"] == 7
    assert rep_thresh["aaLike"] == 6

    w, h, rows = _read_png(out_png)
    assert (w, h) == (8, 8)
    assert rows[2][2] == (255, 255, 0, 255)
    assert rows[1][6] == (255, 0, 255, 255)


def test_compare_ignore_regions_and_lines_cols(tmp_path: Path) -> None:
    w, h = 5, 5
    base_px = [(255, 255, 255, 255)] * (w * h)
    comp_px = list(base_px)
    comp_px[0 * w + 1] = (240, 240, 240, 255)
    comp_px[2 * w + 3] = (0, 0, 0, 255)
    comp_px[4 * w + 4] = (255, 0, 0, 255)

    a = _make_png(tmp_path / "a.png", w, h, base_px)
    b = _make_png(tmp_path / "b.png", w, h, comp_px)

    rep_all = okdiff.compare(a, b, ["--output-diff-lines", "--output-diff-cols"])
    assert rep_all["diffLines"] == [0, 2, 4]
    assert rep_all["diffCols"] == [1, 3, 4]

    rep_thresh = okdiff.compare(
        a, b, ["-t", "0.2", "--output-diff-lines", "--output-diff-cols"]
    )
    assert rep_thresh["overThreshold"] == 2
    assert rep_thresh["diffLines"] == [2, 4]
    assert rep_thresh["diffCols"] == [3, 4]

    rep_ign = okdiff.compare(
        a,
        b,
        ["-i", "0:0-1:1,4:4-4:4", "--output-diff-lines", "--output-diff-cols"],
    )
    assert rep_ign["ignored"] == 5
    assert rep_ign["ignoredDiff"] == 2
    assert rep_ign["identical"] == 19
    assert rep_ign["nonidentical"] == 1
    assert rep_ign["identical"] + rep_ign["nonidentical"] + rep_ign["ignored"] == 25
    assert rep_ign["diffLines"] == [2]
    assert rep_ign["diffCols"] == [3]


def test_compare_dimension_mismatch_overhang(tmp_path: Path) -> None:
    base_px = [(255, 0, 0, 255)] * (5 * 3)
    comp_px = [(255, 0, 0, 255)] * (3 * 3) + [(0, 0, 0, 0)] * 3

    a = _make_png(tmp_path / "a.png", 5, 3, base_px)
    b = _make_png(tmp_path / "b.png", 3, 4, comp_px)
    rep = okdiff.compare(a, b)
    assert rep["base"] == {"w": 5, "h": 3}
    assert rep["comp"] == {"w": 3, "h": 4}
    assert rep["identical"] == 9
    assert rep["nonidentical"] == 0
    assert rep["overhangBase"] == 6
    assert rep["overhangBaseOpaque"] == 6
    assert rep["overhangComp"] == 3
    assert rep["overhangCompOpaque"] == 0

    base_mixed = []
    for y in range(3):
        for x in range(5):
            if x >= 3 and y == 0:
                base_mixed.append((0, 0, 0, 0))
            else:
                base_mixed.append((255, 0, 0, 255))
    comp_opaque = [(255, 0, 0, 255)] * (3 * 3) + [(0, 0, 255, 255)] * 3

    a2 = _make_png(tmp_path / "a2.png", 5, 3, base_mixed)
    b2 = _make_png(tmp_path / "b2.png", 3, 4, comp_opaque)
    rep2 = okdiff.compare(a2, b2)
    assert rep2["overhangBase"] == 6
    assert rep2["overhangBaseOpaque"] == 4
    assert rep2["overhangComp"] == 3
    assert rep2["overhangCompOpaque"] == 3


def test_compare_alpha_blending_onto_white(tmp_path: Path) -> None:
    a = _make_png(
        tmp_path / "a.png",
        3,
        1,
        [(0, 0, 0, 128), (255, 0, 0, 0), (255, 255, 255, 128)],
    )
    b_white_match = _make_png(
        tmp_path / "b_match.png",
        3,
        1,
        [(127, 127, 127, 255), (255, 255, 255, 255), (255, 255, 255, 255)],
    )
    b_black = _make_png(
        tmp_path / "b_black.png",
        3,
        1,
        [(0, 0, 0, 255), (0, 0, 0, 255), (0, 0, 0, 255)],
    )

    rep_plain = okdiff.compare(a, b_white_match)
    assert rep_plain["identical"] == 3
    assert rep_plain["nonidentical"] == 0

    bin_match = tmp_path / "match.delta"
    rep_match = okdiff.compare(a, b_white_match, ["-t", "0", "--delta-bin", str(bin_match)])
    assert rep_match["identical"] == 3
    assert rep_match["nonidentical"] == 0
    assert rep_match["overThreshold"] == 0
    db_match = okdiff.read_delta_bin(bin_match)
    assert db_match.at(0, 0) == 0.0
    assert db_match.at(1, 0) == 0.0
    assert db_match.at(2, 0) == 0.0

    bin_black = tmp_path / "black.delta"
    rep_black = okdiff.compare(a, b_black, ["-t", "0", "--delta-bin", str(bin_black)])
    assert rep_black["identical"] == 0
    assert rep_black["nonidentical"] == 3
    assert rep_black["overThreshold"] == 3
    db_black = okdiff.read_delta_bin(bin_black)
    assert db_black.at(0, 0) > 0.4
    assert db_black.at(1, 0) == pytest.approx(1.0, abs=1e-4)
    assert db_black.at(2, 0) == pytest.approx(1.0, abs=1e-4)


def test_output_pngs_mask_overlay_and_delta_map(tmp_path: Path) -> None:
    a = _make_png(tmp_path / "a.png", 4, 3, [(0, 0, 0, 255)] * 12)
    b_px = [(0, 0, 0, 255)] * 12
    b_px[0] = (255, 0, 0, 255)
    b_px[1] = (200, 200, 200, 255)
    b = _make_png(tmp_path / "b.png", 4, 3, b_px)

    mask_png = tmp_path / "mask.png"
    okdiff.compare(a, b, [str(mask_png), "--diff-mask", "--diff-color", "\x2300ff00"])
    mw, mh, mrows = _read_png(mask_png)
    assert (mw, mh) == (4, 3)
    assert mrows[0][0] == (0, 255, 0, 255)
    assert mrows[0][1] == (0, 255, 0, 255)
    assert mrows[0][2] == (0, 0, 0, 0)

    overlay_png = tmp_path / "overlay.png"
    okdiff.compare(a, b, [str(overlay_png), "--diff-overlay", "0.5"])
    ow, oh, orows = _read_png(overlay_png)
    assert (ow, oh) == (4, 3)
    assert orows[0][0] == (255, 0, 0, 255)
    assert orows[0][2] == (127, 127, 127, 255)

    dmap1_png = tmp_path / "dmap1.png"
    dmap2_png = tmp_path / "dmap2.png"
    okdiff.compare(a, b, [str(dmap1_png), "--delta-map"])
    okdiff.compare(a, b, [str(dmap2_png), "--delta-map=2.0"])
    dw, dh, drows1 = _read_png(dmap1_png)
    _, _, drows2 = _read_png(dmap2_png)
    assert (dw, dh) == (4, 3)
    assert drows1[0][2] == (0, 0, 0, 255)
    assert drows1[0][0][0] == drows1[0][0][1] == drows1[0][0][2]
    assert drows1[0][0][0] > 0
    assert drows1[0][0][3] == 255
    assert drows2[0][1][0] > drows1[0][1][0]

    b_small = _make_png(tmp_path / "b_small.png", 3, 2, [(0, 0, 0, 255)] * 6)
    oh_dmap = tmp_path / "oh_dmap.png"
    okdiff.compare(a, b_small, [str(oh_dmap), "--delta-map"])
    ohw, ohh, ohrows = _read_png(oh_dmap)
    assert (ohw, ohh) == (4, 3)
    assert ohrows[0][0] == (0, 0, 0, 255)
    assert ohrows[0][3] == (0, 0, 0, 0)
    assert ohrows[2][0] == (0, 0, 0, 0)


def test_read_delta_bin_and_bounds(tmp_path: Path) -> None:
    a = _make_png(tmp_path / "a.png", 5, 3, [(255, 255, 255, 255)] * 15)
    b_px = [(255, 255, 255, 255)] * 9
    b_px[1] = (0, 0, 0, 255)
    b = _make_png(tmp_path / "b.png", 3, 3, b_px)
    delta_path = tmp_path / "out.delta"

    okdiff.compare(a, b, ["-i", "2:0-2:1", "--delta-bin", str(delta_path)])
    db = okdiff.read_delta_bin(delta_path)
    assert db.width == 5
    assert db.height == 3
    assert len(db.values) == 15
    assert db.at(0, 0) == 0.0
    assert db.at(1, 0) == pytest.approx(1.0, abs=1e-4)
    assert math.isnan(db.at(2, 0))
    assert math.isnan(db.at(2, 1))
    assert math.isnan(db.at(3, 0))
    assert math.isnan(db.at(4, 2))

    for bad_x, bad_y in [(-1, 0), (0, -1), (5, 0), (0, 3), (5, 3)]:
        with pytest.raises(IndexError):
            db.at(bad_x, bad_y)


def test_read_delta_bin_malformed(tmp_path: Path) -> None:
    empty = tmp_path / "empty.delta"
    empty.write_bytes(b"")
    with pytest.raises(okdiff.OkdiffError):
        okdiff.read_delta_bin(empty)

    short_hdr = tmp_path / "short.delta"
    short_hdr.write_bytes(b"\x01\x00\x00\x00")
    with pytest.raises(okdiff.OkdiffError):
        okdiff.read_delta_bin(short_hdr)

    truncated = tmp_path / "truncated.delta"
    truncated.write_bytes(struct.pack("<II", 2, 2) + b"\x00" * 12)
    with pytest.raises(okdiff.OkdiffError):
        okdiff.read_delta_bin(truncated)

    trailing = tmp_path / "trailing.delta"
    trailing.write_bytes(struct.pack("<II", 1, 1) + b"\x00" * 8)
    with pytest.raises(okdiff.OkdiffError):
        okdiff.read_delta_bin(trailing)


def test_compare_dir_pairs_isolation_and_outputs(tmp_path: Path) -> None:
    dir_a = tmp_path / "dir_a"
    dir_b = tmp_path / "dir_b"
    diff_dir = tmp_path / "diff_dir"
    delta_dir = tmp_path / "delta_dir"
    dir_a.mkdir()
    dir_b.mkdir()

    white = [(255, 255, 255, 255)] * 16
    changed = list(white)
    changed[0 * 4 + 1] = (0, 0, 0, 255)
    changed[3 * 4 + 2] = (255, 0, 0, 255)

    _make_png(dir_a / "same.png", 4, 4, white)
    _make_png(dir_b / "same.png", 4, 4, white)
    _make_png(dir_a / "changed.png", 4, 4, white)
    _make_png(dir_b / "changed.png", 4, 4, changed)
    (dir_a / "corrupt.png").write_bytes(b"not a valid png")
    (dir_b / "corrupt.png").write_bytes(b"not a valid png")
    _make_png(dir_a / "only_a.png", 2, 2, [(0, 0, 0, 255)] * 4)
    _make_png(dir_b / "only_b.png", 2, 2, [(0, 0, 0, 255)] * 4)

    rep = okdiff.compare_dir(
        dir_a,
        dir_b,
        [
            "--diff-dir",
            str(diff_dir),
            "--delta-bin",
            str(delta_dir),
            "--output-diff-lines",
            "--output-diff-cols",
            "-j",
            "1",
        ],
    )
    assert rep["onlyInA"] == ["only_a"]
    assert rep["onlyInB"] == ["only_b"]

    by_stem = {item["stem"]: item for item in rep["pairs"]}
    assert set(by_stem) == {"same", "changed", "corrupt"}

    assert by_stem["same"]["identical"] == 16
    assert by_stem["same"]["nonidentical"] == 0
    assert "error" not in by_stem["same"]

    assert by_stem["changed"]["identical"] == 14
    assert by_stem["changed"]["nonidentical"] == 2
    assert by_stem["changed"]["diffLines"] == [0, 3]
    assert by_stem["changed"]["diffCols"] == [1, 2]
    assert "error" not in by_stem["changed"]

    assert "error" in by_stem["corrupt"]
    assert len(by_stem["corrupt"]["error"]) > 0

    assert (diff_dir / "same.png").is_file()
    assert (diff_dir / "changed.png").is_file()
    db_same = okdiff.read_delta_bin(delta_dir / "same.delta")
    db_changed = okdiff.read_delta_bin(delta_dir / "changed.delta")
    assert db_same.at(0, 0) == 0.0
    assert db_changed.at(1, 0) > 0.0
    assert db_changed.at(2, 3) > 0.0


def test_okdiff_server_sequential_and_all_options(tmp_path: Path) -> None:
    a, b = _make_aa_pair(tmp_path, "srv")
    ov_png = tmp_path / "srv_overlay.png"
    dmap_png = tmp_path / "srv_dmap.png"
    dbin_path = tmp_path / "srv.delta"

    with okdiff.OkdiffServer() as srv:
        r1 = srv.compare({"base": str(a), "comp": str(a)})
        assert r1["requestId"] == 1
        assert r1["identical"] == 64
        assert r1["nonidentical"] == 0

        r2 = srv.compare(
            {
                "base": str(a),
                "comp": str(b),
                "diff": str(ov_png),
                "diffOverlay": 0.5,
                "diffColor": "\x2300ff00",
                "antialiasing": True,
                "aaColor": "\x2300ffff",
                "diffLines": True,
                "diffCols": True,
            }
        )
        assert r2["requestId"] == 2
        assert r2["identical"] == 57
        assert r2["nonidentical"] == 7
        assert r2["aaLike"] == 6
        assert r2["diffLines"] == [1, 2, 3, 4, 5, 6]
        assert r2["diffCols"] == [1, 2, 3, 4, 5, 6]

        ow, oh, orows = _read_png(ov_png)
        assert (ow, oh) == (8, 8)
        assert orows[2][2] == (0, 255, 255, 255)
        assert orows[1][6] == (0, 255, 0, 255)
        assert orows[5][0] == (127, 127, 127, 255)

        r3 = srv.compare(
            {
                "base": str(a),
                "comp": str(b),
                "diff": str(dmap_png),
                "deltaMap": 2.0,
                "deltaBin": str(dbin_path),
                "ignoreRegions": [{"x1": 1, "y1": 1, "x2": 1, "y2": 1}],
                "diffLines": True,
                "diffCols": True,
            }
        )
        assert r3["requestId"] == 3
        assert r3["ignored"] == 1
        assert r3["ignoredDiff"] == 1
        assert r3["nonidentical"] == 6
        assert r3["diffLines"] == [1, 2, 3, 4, 5, 6]
        assert r3["diffCols"] == [2, 3, 4, 5, 6]

        dw, dh, drows = _read_png(dmap_png)
        assert (dw, dh) == (8, 8)
        assert drows[2][2] == (204, 204, 204, 255)
        db = okdiff.read_delta_bin(dbin_path)
        assert math.isnan(db.at(1, 1))
        assert db.at(2, 2) > 0.0
        assert db.at(0, 0) == 0.0


def test_okdiff_server_error_recovery_and_close(tmp_path: Path) -> None:
    a = _make_png(tmp_path / "a.png", 2, 2, [(255, 255, 255, 255)] * 4)
    b = _make_png(
        tmp_path / "b.png",
        2,
        2,
        [(0, 0, 0, 255), (255, 255, 255, 255), (255, 255, 255, 255), (255, 255, 255, 255)],
    )

    with okdiff.OkdiffServer() as srv:
        with pytest.raises(okdiff.OkdiffError):
            srv.compare({"base": str(tmp_path / "missing.png"), "comp": str(b)})

        with pytest.raises(okdiff.OkdiffError, match="unknown metric"):
            srv.compare({"base": str(a), "comp": str(b), "metric": "bogus"})

        with pytest.raises(okdiff.OkdiffError, match="bad threshold"):
            srv.compare({"base": str(a), "comp": str(b), "threshold": -1})

        recovered = srv.compare({"base": str(a), "comp": str(b)})
        assert recovered["identical"] == 3
        assert recovered["nonidentical"] == 1
        assert recovered["requestId"] == 4

        srv.close()
        srv.close()
        with pytest.raises(okdiff.OkdiffError):
            srv.compare({"base": str(a), "comp": str(b)})

    with pytest.raises(okdiff.OkdiffError):
        srv.compare({"base": str(a), "comp": str(b)})
    srv.close()


def test_cli_errors_and_missing_binary(tmp_path: Path) -> None:
    a = _make_png(tmp_path / "a.png", 2, 2, [(0, 0, 0, 255)] * 4)
    b = _make_png(tmp_path / "b.png", 2, 2, [(255, 255, 255, 255)] * 4)

    with pytest.raises(okdiff.OkdiffError) as missing_exc:
        okdiff.compare(tmp_path / "nope.png", b)
    assert missing_exc.value.exit_code == 2

    with pytest.raises(okdiff.OkdiffError) as thresh_exc:
        okdiff.compare(a, b, ["-t", "-1"])
    assert thresh_exc.value.exit_code == 2

    with pytest.raises(okdiff.OkdiffError) as bad_num_exc:
        okdiff.compare(a, b, ["-t", "nan"])
    assert bad_num_exc.value.exit_code == 2

    with pytest.raises(okdiff.OkdiffError) as metric_exc:
        okdiff.compare(a, b, ["--metric", "bogus"])
    assert metric_exc.value.exit_code == 2

    missing_bin = tmp_path / "does_not_exist_okdiff"
    with pytest.raises(okdiff.OkdiffError) as bin_cmp_exc:
        okdiff.compare(a, b, binary=missing_bin)
    assert bin_cmp_exc.value.exit_code is None

    with pytest.raises(okdiff.OkdiffError) as bin_dir_exc:
        okdiff.compare_dir(tmp_path, tmp_path, binary=missing_bin)
    assert bin_dir_exc.value.exit_code is None

    with pytest.raises(okdiff.OkdiffError) as bin_srv_exc:
        okdiff.OkdiffServer(binary=missing_bin)
    assert bin_srv_exc.value.exit_code is None
