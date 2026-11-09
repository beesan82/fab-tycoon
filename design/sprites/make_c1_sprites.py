#!/usr/bin/env python3
"""C1 (CMP) スプライト生成スクリプト（P5 第1ゲート用）。

入力: 承認済み CMP サンプル（単体・正面 3/4 俯瞰・無地背景、1920x1280 RGB、アルファなし）
出力:
  - eq_c1_front_body.png : 背景を除去した本体カットアウト（可動部は含んだまま）
  - eq_c1_front_mov1.png : プラテン（研磨盤）だけを切り出し、楕円→正円に補正した回転用テクスチャ

限界（gate1-log.md に詳述）:
  - 本体側のプラテン欠損はインペイントしていない（mov1 は本体の上に重ねる前提）。
  - ロボットアーム（mov2 想定）は分離していない。
  - シグナルタワーは本体に焼き込まれたまま（全色点灯）。本番では生成段階で消すか
    インペイントで消し、共通ランプ部品＋コード描画に寄せる。
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

SRC = Path.home() / "workspace/your_files/media-generation-fab-cmp-sample-0-912f0407-06a6-466f-a70f-eae724dd173f.webp"
OUT = Path(__file__).parent / "generated"
OUT.mkdir(exist_ok=True)

# プラテン外周（1920x1280 座標での目視計測値。生成画像の個体差でずれる前提）
PLATEN_BBOX = (482, 394, 1368, 918)  # left, top, right, bottom（実測で補正済み）
BODY_WIDTH = 576  # 2x2 装置: 仕様 288px(基準) の 2 倍解像度。864 では 749KB と仕様帯(80-400KB/点)を超過したため


def remove_background(img: Image.Image, tol: int = 20) -> Image.Image:
    """四隅の平均色に近い画素のうち、画像端に連結しているものだけを背景として抜く。
    本体内部の白っぽい部品（アーム等）は端に連結しないので残る。"""
    arr = np.asarray(img).astype(np.int16)
    corners = np.concatenate([
        arr[:40, :40].reshape(-1, 3), arr[:40, -40:].reshape(-1, 3),
        arr[-40:, :40].reshape(-1, 3), arr[-40:, -40:].reshape(-1, 3)])
    bg = corners.mean(axis=0)
    dist = np.abs(arr - bg).max(axis=2)
    like_bg = dist <= tol
    labels, _ = ndimage.label(like_bg)
    border_labels = set(np.unique(np.concatenate(
        [labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]]))) - {0}
    bg_mask = np.isin(labels, list(border_labels))
    alpha = np.where(bg_mask, 0, 255).astype(np.uint8)
    out = img.convert("RGBA")
    a = Image.fromarray(alpha).filter(ImageFilter.GaussianBlur(0.7))
    out.putalpha(a)
    return out


def main() -> None:
    img = Image.open(SRC).convert("RGB")
    print("src", img.size)

    cut = remove_background(img)
    bbox = cut.getbbox()
    print("machine bbox", bbox)
    body = cut.crop(bbox)
    scale = BODY_WIDTH / body.width
    body = body.resize((BODY_WIDTH, round(body.height * scale)), Image.LANCZOS)
    body.save(OUT / "eq_c1_front_body.png")
    print("body", body.size)

    # プラテン: 楕円 bbox を切り出し、正円化して回転用テクスチャにする
    platen = img.crop(PLATEN_BBOX).resize((320, 320), Image.LANCZOS).convert("RGBA")  # 描画最大 ~255px@3x に対し 320 で足りる
    mask = Image.new("L", (320, 320), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(mask).ellipse([4, 4, 316, 316], fill=255)
    platen.putalpha(mask.filter(ImageFilter.GaussianBlur(1.2)))
    platen.save(OUT / "eq_c1_front_mov1.png")
    print("mov1", platen.size)

    meta = {
        "src_size": img.size,
        "machine_bbox": bbox,
        "platen_bbox_src": PLATEN_BBOX,
        "platen_center_rel": [
            (PLATEN_BBOX[0] + PLATEN_BBOX[2]) / 2 / img.width,
            (PLATEN_BBOX[1] + PLATEN_BBOX[3]) / 2 / img.height],
        "lamp_tower_rel": [1608 / img.width, 218 / img.height],
    }
    (OUT / "measure.json").write_text(json.dumps(meta, indent=2))
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
