#!/usr/bin/env python3
"""初期7機種の残り6機種（L1, D1, E1, I1, Q1, P1）の本体スプライト量産スクリプト（P5 第2ゲート）。

方針（gate1-log.md の学び）:
  - 生成は「2機種を横並び・無地明背景・シグナルタワーなし」で行い、本スクリプトで個体に分割する
  - 背景除去は make_c1_sprites.py のフラッドフィル方式をそのまま再利用
  - 可動部は作らない（本体のみ）。状態ランプはコード描画が正

入力: design/sprites/raw/ の生成 webp（2機種/枚）
出力: design/sprites/generated/eq_<id>_front_body.png ＋ measure2.json（実測記録）
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

HERE = Path(__file__).parent
RAW = HERE / "raw"
OUT = HERE / "generated"
OUT.mkdir(exist_ok=True)

SIZE_LIMIT = 400 * 1024  # redesign §5.4 本体 80〜400KB/点

# (raw ファイル名の一部, 左機種, 右機種, 目標幅px)
JOBS = [
    ("eq-l1-i1-raw", "l1", "i1", {"l1": 768, "i1": 768}),
    ("eq-d1-e1-raw", "d1", "e1", {"d1": 576, "e1": 576}),
    ("eq-q1-p1-raw", "q1", "p1", {"q1": 576, "p1": 576}),
]


def remove_background(img: Image.Image, tol: int = 20) -> Image.Image:
    """make_c1_sprites.py と同一手法：四隅の平均色に近く画像端に連結した画素だけを背景として抜く。
    第2ゲートでの改良：床の落ち影は「全チャンネルで背景より暗い」方向にだけ色がずれるため、
    暗い側の許容差を広げる（影のコアが本体にくっついて残る問題への対処）。"""
    arr = np.asarray(img).astype(np.int16)
    corners = np.concatenate([
        arr[:40, :40].reshape(-1, 3), arr[:40, -40:].reshape(-1, 3),
        arr[-40:, :40].reshape(-1, 3), arr[-40:, -40:].reshape(-1, 3)])
    bg = corners.mean(axis=0)
    diff = arr - bg
    dist = np.abs(diff).max(axis=2)
    darker = (diff <= 6).all(axis=2) & (dist <= 36)  # 影：全チャンネルで暗い側
    like_bg = (dist <= tol) | darker
    labels, _ = ndimage.label(like_bg)
    border_labels = set(np.unique(np.concatenate(
        [labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]]))) - {0}
    bg_mask = np.isin(labels, list(border_labels))
    alpha = np.where(bg_mask, 0, 255).astype(np.uint8)
    out = img.convert("RGBA")
    a = Image.fromarray(alpha).filter(ImageFilter.GaussianBlur(0.7))
    out.putalpha(a)
    return out


def _clean_fragments(mask: np.ndarray) -> np.ndarray:
    """最大成分を本体とし、本体マスクを 20px 膨らませた範囲に触れる成分だけ残す。
    （bbox 基準だと他機種の断片が bbox 内に紛れて残ったため、マスク近接基準に変更）"""
    labels, n = ndimage.label(mask)
    if n == 0:
        return mask
    sizes = ndimage.sum(mask, labels, range(1, n + 1))
    main_label = int(np.argmax(sizes)) + 1
    dilated = ndimage.binary_dilation(labels == main_label, iterations=20)
    keep_labels = {main_label}
    for i in range(1, n + 1):
        if i != main_label and (dilated & (labels == i)).any():
            keep_labels.add(i)
    return np.isin(labels, list(keep_labels))


def _fill_holes(mask: np.ndarray) -> np.ndarray:
    """切り抜き後の画像内で、画像端に接しない透明領域＝本体内部の抜け穴として埋める。
    白いパネル面が背景色に近くフラッドフィルが漏れて穴になる機種（Q1）への対処。"""
    transparent = ~mask
    labels, n = ndimage.label(transparent)
    if n == 0:
        return mask
    border = set(np.unique(np.concatenate(
        [labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]]))) - {0}
    holes = transparent & ~np.isin(labels, list(border))
    return mask | holes


def split_two(cut: Image.Image) -> tuple[Image.Image, Image.Image]:
    """中央付近で不透明画素が最も少ない縦列を分割線にし、左右に割る。
    （第1試行の重心・最近傍割当は斜めの切断線を作って失敗したため、この方式に変更）"""
    alpha = np.asarray(cut)[:, :, 3]
    mask = alpha > 10
    col = mask.sum(axis=0)
    lo, hi = mask.shape[1] // 3, mask.shape[1] * 2 // 3
    split_x = lo + int(np.argmin(col[lo:hi]))
    arr = np.asarray(cut).copy()
    results = []
    for side_mask in (np.arange(mask.shape[1])[None, :] < split_x,
                      np.arange(mask.shape[1])[None, :] >= split_x):
        m = _fill_holes(_clean_fragments(mask & side_mask))
        a = np.where(m, arr[:, :, 3], 0).astype(np.uint8)
        img = Image.fromarray(np.dstack([arr[:, :, :3], a]), "RGBA")
        results.append(img.crop(img.getbbox()))
    return results[0], results[1]


def process_single(cut: Image.Image) -> Image.Image:
    """1機種だけ写った生成画像の切り抜き（分割なし）。"""
    alpha = np.asarray(cut)[:, :, 3]
    m = _fill_holes(_clean_fragments(alpha > 10))
    arr = np.asarray(cut).copy()
    a = np.where(m, arr[:, :, 3], 0).astype(np.uint8)
    img = Image.fromarray(np.dstack([arr[:, :, :3], a]), "RGBA")
    return img.crop(img.getbbox())


def fit_size(img: Image.Image, target_w: int, path: Path) -> tuple[int, int, int]:
    """目標幅で保存し、仕様帯を超えたら幅を段階的に落として収める。"""
    w = target_w
    while True:
        h = round(img.height * w / img.width)
        resized = img.resize((w, h), Image.LANCZOS)
        resized.save(path, optimize=True)
        size = path.stat().st_size
        if size <= SIZE_LIMIT or w <= 320:
            return w, h, size
        w = int(w * 0.85)


# 単体生成で作り直した機種（ペア生成では斜め構図が分割できなかった I1）
SINGLES = [
    ("eq-i1-single-raw", "i1", 1152),
]


def main() -> None:
    records = {}
    for key, left_id, right_id, widths in JOBS:
        srcs = sorted(RAW.glob(f"*{key}*.webp"))
        if not srcs:
            raise FileNotFoundError(key)
        img = Image.open(srcs[0]).convert("RGB")
        print("src", srcs[0].name, img.size)
        cut = remove_background(img)
        left, right = split_two(cut)
        for model_id, part in ((left_id, left), (right_id, right)):
            if any(s[1] == model_id for s in SINGLES):
                continue  # 単体生成で作り直す機種はペア側を使わない
            out_path = OUT / f"eq_{model_id}_front_body.png"
            w, h, size = fit_size(part, widths[model_id], out_path)
            records[model_id] = {
                "src": srcs[0].name,
                "crop_size": [part.width, part.height],
                "pixel_size": [w, h],
                "bytes": size,
            }
            print(model_id, records[model_id])
    for key, model_id, width in SINGLES:
        srcs = sorted(RAW.glob(f"*{key}*.webp"))
        if not srcs:
            raise FileNotFoundError(key)
        img = Image.open(srcs[0]).convert("RGB")
        print("src(single)", srcs[0].name, img.size)
        part = process_single(remove_background(img))
        out_path = OUT / f"eq_{model_id}_front_body.png"
        w, h, size = fit_size(part, width, out_path)
        records[model_id] = {
            "src": srcs[0].name,
            "crop_size": [part.width, part.height],
            "pixel_size": [w, h],
            "bytes": size,
        }
        print(model_id, records[model_id])
    (OUT / "measure2.json").write_text(json.dumps(records, indent=2, ensure_ascii=False))
    print(json.dumps(records, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
