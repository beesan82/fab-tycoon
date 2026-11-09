#!/usr/bin/env python3
"""P5 第3ゲート: 初期7機種の本体スプライトをドット絵（ピクセルアート）で作り直す。

方式: ネイティブ解像度（最終の 1/4）で PIL プリミティブにより手続き描画し、
シルエット輪郭パス（アルファ膨張で太輪郭を付与）を通してから ×4 NEAREST 拡大する。
グリッドが揃った意図的なピクセル感が得られ、色数も制限される。

スタイル基準（gate3-dot-log.md にも記載）:
- 輪郭: 全パーツ 1dot の濃紺グレー #222636 + シルエット外周にもう 1dot（膨張パス）
- 共通パレット: クリーンルーム白〜グレーの 4 階調 + 工程アクセント色（LineView.swift の
  ProcessType.accent と同色系）+ ガラス色 + FOUP ベージュ（コード描画 FOUP と同系色）
- 画角: 正面〜やや見下ろし（上面と右側面が見える箱型表現、奥行き 4〜5dot）
- シグナルタワーは描かない（状態ランプはコード描画が正）

出力: design/sprites/generated/eq_<id>_front_body.png（マスター）と
      FabTycoon/Assets.xcassets/eq_<id>_front_body.imageset/ へ同一バイトを配置。
"""
from PIL import Image, ImageDraw, ImageFilter
import math
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCALE = 4

# --- 共通パレット (RGB) ---
OUT = (34, 38, 54)          # 輪郭 #222636
HI = (242, 245, 250)        # 本体ハイライト（上面）
BODY = (216, 223, 233)      # 本体
MID = (168, 180, 198)       # 本体ミドル（側面・帯）
DARK = (118, 130, 150)      # 本体ダーク
DEEP = (74, 82, 100)        # 濃い面（ underside 等）
GLASS = (148, 214, 238)     # 窓・レンズガラス
GLASS_HI = (235, 250, 255)  # ガラスのハイライト
FOUP = (238, 222, 179)      # FOUP ベージュ（コード描画と同系）
FOUP_D = (203, 182, 128)    # FOUP 影色
GOLD = (242, 201, 92)       # チップ等の金
WHITE = (255, 255, 255)

ACCENT = {
    "c1": (56, 132, 255),    # CMP = blue
    "l1": (255, 149, 0),     # 露光 = orange
    "d1": (45, 180, 190),    # 成膜 = teal
    "e1": (168, 92, 210),    # エッチ = purple
    "i1": (52, 199, 89),     # 注入 = green
    "q1": (88, 86, 214),     # 検査 = indigo
    "p1": (162, 132, 94),    # PKG = brown
}


def canvas(w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def shadow(img, box):
    """接地影（輪郭パスの対象外なので先に別レイヤーへ描く想定で単体画像を返す）"""
    s = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(s)
    d.ellipse(box, fill=(18, 22, 36, 82))
    return s


def box3d(d, x, y, w, h, dep=5, front=BODY, top=HI, side=MID):
    """上面と右側面が見える箱。前面は (x, y, w, h)。"""
    d.polygon([(x, y), (x + dep, y - dep), (x + w + dep, y - dep), (x + w, y)],
              fill=top, outline=OUT)
    d.polygon([(x + w, y), (x + w + dep, y - dep), (x + w + dep, y + h - dep),
               (x + w, y + h)], fill=side, outline=OUT)
    d.rectangle([x, y, x + w, y + h], fill=front, outline=OUT)


def rect(d, x, y, w, h, fill, outline=OUT):
    d.rectangle([x, y, x + w, y + h], fill=fill, outline=outline)


def ell(d, cx, cy, rx, ry, fill, outline=OUT):
    d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=fill, outline=outline)


def disk(d, cx, cy, r, fill, outline=OUT):
    ell(d, cx, cy, r, r, fill, outline)


def foup_slot(d, x, y, w, h):
    """前面の FOUP ロードポート（ベージュ + 蓋帯）"""
    rect(d, x, y, w, h, FOUP)
    d.line([(x + 1, y + h * 0.32), (x + w - 1, y + h * 0.32)], fill=FOUP_D)
    rect(d, x + w // 2 - 3, y + h - 6, 6, 3, FOUP_D, outline=None)


def screen(d, x, y, w, h, accent):
    rect(d, x, y, w, h, GLASS)
    d.line([(x + 3, y + h - 4), (x + w // 2, y + 3)], fill=GLASS_HI, width=2)
    rect(d, x + 3, y + h - 6, w - 6, 2, accent, outline=None)


def buttons(d, x, y, colors=((235, 80, 80), (250, 200, 70), (90, 210, 120))):
    for i, c in enumerate(colors):
        rect(d, x + i * 6, y, 3, 3, c)


def sparkle(d, cx, cy, s=3):
    d.line([(cx - s, cy), (cx + s, cy)], fill=WHITE)
    d.line([(cx, cy - s), (cx, cy + s)], fill=WHITE)


def finish(art, shad):
    """輪郭パス（アルファ膨張でシルエットに 1dot の太輪郭）→ 影と合成 → ×4 拡大"""
    alpha = art.split()[3]
    dilated = alpha.filter(ImageFilter.MaxFilter(3))
    ring = Image.new("RGBA", art.size, OUT + (0,))
    ring.putalpha(dilated)
    out = shad
    out.alpha_composite(ring)
    out.alpha_composite(art)
    return out.resize((art.size[0] * SCALE, art.size[1] * SCALE), Image.NEAREST)


# ---------------------------------------------------------------- C1 CMP
def draw_c1():
    W, H = 144, 140
    img, d = canvas(W, H)
    shad = shadow(img, (12, 124, 132, 138))
    acc = ACCENT["c1"]
    # 筐体
    box3d(d, 24, 84, 96, 48, dep=5)
    # デッキ
    rect(d, 17, 74, 110, 10, MID)
    # プラテン（大円盤・同心リング）
    ell(d, 72, 64, 48, 18, DARK)
    ell(d, 72, 64, 44, 16, acc, outline=None)
    ell(d, 72, 64, 34, 12, (96, 155, 235), outline=None)
    ell(d, 72, 64, 24, 8, acc, outline=None)
    ell(d, 72, 64, 13, 5, (96, 155, 235), outline=None)
    disk(d, 72, 64, 4, HI)
    # 研磨ヘッド（アーム + ヘッド）
    rect(d, 112, 38, 10, 38, MID)
    rect(d, 82, 36, 38, 9, BODY)
    ell(d, 88, 56, 15, 8, DEEP)          # ヘッド裏面（プラテンに接する側）
    ell(d, 88, 52, 15, 8, HI)
    # コンディショナ小円盤
    rect(d, 33, 46, 5, 12, MID)
    ell(d, 36, 58, 10, 5, DARK)
    ell(d, 36, 57, 8, 4, MID, outline=None)
    # 前面: アクセント帯・画面・FOUP スロット×2
    rect(d, 25, 90, 94, 5, acc, outline=None)
    screen(d, 32, 100, 24, 18, acc)
    foup_slot(d, 64, 102, 24, 26)
    foup_slot(d, 94, 102, 24, 26)
    sparkle(d, 18, 34)
    sparkle(d, 128, 24, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- L1 露光
def draw_l1():
    W, H = 160, 144
    img, d = canvas(W, H)
    shad = shadow(img, (4, 128, 156, 142))
    acc = ACCENT["l1"]
    # 本体キャビネット
    box3d(d, 8, 92, 104, 40, dep=5)
    # 左上の小ユニット（レチクル側）
    box3d(d, 14, 76, 26, 16, dep=4)
    disk(d, 27, 84, 3, acc)
    # レンズ塔
    box3d(d, 56, 34, 36, 58, dep=4)
    box3d(d, 50, 24, 48, 12, dep=4, front=MID, top=HI)
    # レンズ（同心円）
    disk(d, 74, 57, 14, DARK)
    disk(d, 74, 57, 10, (104, 96, 220), outline=None)
    disk(d, 74, 57, 6, (150, 140, 245), outline=None)
    disk(d, 74, 57, 2, WHITE, outline=None)
    d.point((69, 51), fill=GLASS_HI)
    d.point((70, 50), fill=GLASS_HI)
    # ステージ + ウエハ + 露光スリット光
    rect(d, 44, 84, 60, 8, MID)
    ell(d, 74, 87, 17, 4, (203, 211, 224))
    rect(d, 59, 86, 30, 2, acc, outline=None)
    # 右コントロールユニット
    box3d(d, 110, 64, 38, 68, dep=5)
    screen(d, 117, 72, 25, 20, acc)
    rect(d, 111, 100, 36, 5, acc, outline=None)
    buttons(d, 118, 112)
    rect(d, 117, 122, 25, 5, DARK, outline=None)
    # 前面 FOUP スロット×3
    foup_slot(d, 15, 105, 22, 22)
    foup_slot(d, 43, 105, 22, 22)
    foup_slot(d, 71, 105, 22, 22)
    sparkle(d, 146, 30)
    return finish(img, shad)


# ---------------------------------------------------------------- D1 成膜
def draw_d1():
    W, H = 144, 148
    img, d = canvas(W, H)
    shad = shadow(img, (8, 132, 136, 146))
    acc = ACCENT["d1"]
    # プラットフォーム
    box3d(d, 14, 106, 116, 34, dep=5)
    # 背面の小スタック
    rect(d, 18, 94, 8, 12, MID)
    rect(d, 118, 94, 8, 12, MID)
    # 接続パイプ（チャンバーより先に描く）
    rect(d, 40, 80, 16, 6, DARK)
    rect(d, 88, 80, 16, 6, DARK)
    rect(d, 68, 42, 8, 14, DARK)
    # サテライトポッド×3（円筒 + 楕円蓋）
    for cx, cy, r in ((30, 84, 12), (114, 84, 12), (72, 34, 10)):
        rect(d, cx - r + 1, cy - 4, (r - 1) * 2, 20 if r == 12 else 16, BODY)
        ell(d, cx, cy - 4, r, r // 2 + 2, HI)
        ell(d, cx, cy - 4, r // 2, (r // 2) // 2 + 1, acc, outline=None)
    # 中央チャンバー（八角形）
    cx, cy, r = 72, 74, 30
    pts = []
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a) * 0.92))
    d.polygon(pts, fill=BODY, outline=OUT)
    ell(d, 72, 62, 19, 8, HI)
    ell(d, 72, 62, 12, 5, acc, outline=None)
    disk(d, 72, 62, 2, DEEP, outline=None)
    # 前面: 帯・窓・ゲージ
    rect(d, 15, 112, 114, 5, acc, outline=None)
    screen(d, 24, 121, 26, 14, acc)
    for gx in (106, 120):
        disk(d, gx, 127, 4, WHITE)
        d.point((gx, 125), fill=DEEP)
    sparkle(d, 128, 18, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- E1 エッチ
def draw_e1():
    W, H = 144, 190
    img, d = canvas(W, H)
    shad = shadow(img, (10, 172, 134, 186))
    acc = ACCENT["e1"]
    # スクラバー（左の円筒）と接続パイプ
    rect(d, 48, 48, 44, 8, BODY)
    rect(d, 24, 52, 24, 44, BODY)
    ell(d, 36, 52, 12, 6, HI)
    rect(d, 24, 66, 24, 6, acc, outline=None)
    # 排気ダクト（縦・節入り）
    rect(d, 90, 14, 18, 82, BODY)
    for yy in range(26, 96, 14):
        d.line([(91, yy), (107, yy)], fill=DARK)
    rect(d, 84, 8, 30, 7, MID)            # 上部フランジ
    rect(d, 85, 54, 28, 5, MID)           # 中間フランジ
    # ファンボックス
    rect(d, 84, 32, 30, 20, MID)
    disk(d, 99, 42, 6, DARK)
    disk(d, 99, 42, 2, DEEP, outline=None)
    # 本体
    box3d(d, 16, 96, 112, 80, dep=5)
    rect(d, 17, 102, 110, 5, acc, outline=None)
    # チャンバードア（大円・紫ガラス）
    disk(d, 57, 136, 23, HI)
    disk(d, 57, 136, 18, acc, outline=None)
    disk(d, 57, 136, 11, (150, 110, 220), outline=None)
    d.point((50, 129), fill=GLASS_HI)
    d.point((51, 128), fill=GLASS_HI)
    for k in range(6):
        a = math.radians(60 * k + 30)
        d.point((57 + 20 * math.cos(a), 136 + 20 * math.sin(a)), fill=DEEP)
    # 操作パネル
    rect(d, 90, 108, 32, 44, MID)
    screen(d, 95, 113, 22, 15, acc)
    rect(d, 95, 133, 22, 5, acc, outline=None)
    buttons(d, 96, 143)
    # 底部ベント
    for i in range(3):
        d.line([(24, 164 + i * 4), (76, 164 + i * 4)], fill=DARK)
    return finish(img, shad)


# ---------------------------------------------------------------- I1 注入/熱
def draw_i1():
    W, H = 288, 82
    img, d = canvas(W, H)
    shad = shadow(img, (2, 66, 286, 80))
    acc = ACCENT["i1"]
    # 脚
    for lx in (70, 122, 182, 226):
        rect(d, lx, 58, 6, 14, DARK)
    # ビームチューブ
    rect(d, 58, 38, 176, 16, BODY)
    d.line([(59, 42), (233, 42)], fill=HI)
    d.line([(59, 51), (233, 51)], fill=MID)
    for rx in (84, 116, 196, 222):
        rect(d, rx, 35, 6, 22, MID)
    # 真空ポンプ（上面の小箱）
    for px in (96, 160):
        rect(d, px, 28, 14, 10, MID)
        rect(d, px + 4, 24, 6, 4, DARK)
    # ビューポート（緑の小窓）
    for vx in (100, 188):
        disk(d, vx, 46, 3, (140, 240, 170))
    # イオン源キャビネット（左・高め）
    box3d(d, 6, 20, 52, 50, dep=4)
    screen(d, 14, 28, 20, 15, acc)
    rect(d, 7, 50, 50, 5, acc, outline=None)
    buttons(d, 40, 30)
    # 偏向マグネット（中央の箱）
    box3d(d, 128, 26, 40, 44, dep=4, front=MID, top=HI)
    rect(d, 129, 44, 38, 6, acc, outline=None)
    disk(d, 148, 60, 4, DEEP)
    # エンドステーション（右・円筒 + 円ドア）
    rect(d, 236, 26, 40, 44, BODY)
    ell(d, 256, 26, 20, 7, HI)
    disk(d, 256, 48, 11, MID)
    disk(d, 256, 48, 7, (140, 240, 170), outline=None)
    disk(d, 256, 48, 2, DEEP, outline=None)
    rect(d, 237, 62, 38, 5, acc, outline=None)
    sparkle(d, 282, 10, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- Q1 検査
def draw_q1():
    W, H = 144, 256
    img, d = canvas(W, H)
    shad = shadow(img, (22, 238, 122, 252))
    acc = ACCENT["q1"]
    # コラム（背面の柱）
    rect(d, 57, 40, 30, 134, BODY)
    d.line([(63, 42), (63, 172)], fill=MID)
    d.line([(81, 42), (81, 172)], fill=MID)
    rect(d, 57, 82, 30, 4, MID, outline=None)
    rect(d, 57, 122, 30, 4, MID, outline=None)
    # ヘッド
    box3d(d, 46, 18, 52, 26, dep=4)
    rect(d, 52, 12, 40, 6, MID)
    rect(d, 47, 38, 50, 4, acc, outline=None)
    # 双眼部（2つの小円）
    for bx in (62, 82):
        disk(d, bx, 30, 5, DEEP)
        disk(d, bx, 30, 2, GLASS, outline=None)
    # 対物レンズ（下向きコーン）
    d.polygon([(64, 44), (80, 44), (75, 58), (69, 58)], fill=DARK, outline=OUT)
    rect(d, 69, 58, 6, 4, DEEP)
    d.point((72, 63), fill=acc)
    # モニターアーム + モニター
    rect(d, 87, 64, 14, 6, MID)
    box3d(d, 100, 52, 34, 28, dep=3)
    screen(d, 105, 57, 24, 16, acc)
    # ステージハウジング + ウエハステージ
    box3d(d, 38, 172, 68, 30, dep=4)
    ell(d, 72, 170, 24, 7, MID)
    ell(d, 72, 169, 17, 5, (203, 211, 224))
    disk(d, 72, 169, 2, DARK, outline=None)
    # ベースキャビネット
    box3d(d, 28, 200, 88, 44, dep=5)
    rect(d, 29, 205, 86, 5, acc, outline=None)
    foup_slot(d, 37, 214, 24, 24)
    rect(d, 70, 212, 36, 26, MID)
    rect(d, 75, 217, 26, 4, DARK, outline=None)
    buttons(d, 76, 226)
    sparkle(d, 126, 20, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- P1 PKG
def draw_p1():
    W, H = 144, 160
    img, d = canvas(W, H)
    shad = shadow(img, (6, 142, 138, 156))
    acc = ACCENT["p1"]
    reel_tan = (216, 186, 138)
    reel_lt = (230, 205, 165)
    # リールスタンド（テーブルより先）
    rect(d, 102, 76, 8, 28, DARK)
    # ボンダーアーム支柱
    rect(d, 26, 46, 8, 48, BODY)
    # キャビネット
    box3d(d, 12, 102, 120, 44, dep=5)
    # テーブル
    rect(d, 20, 94, 104, 10, MID)
    # リール（大円・テープリール）
    disk(d, 106, 54, 25, reel_tan)
    disk(d, 106, 54, 19, reel_lt, outline=None)
    for hx, hy in ((96, 44), (116, 44), (96, 64), (116, 64)):
        disk(d, hx, hy, 3, (150, 124, 88), outline=None)
    disk(d, 106, 54, 8, MID)
    disk(d, 106, 54, 3, DEEP, outline=None)
    # テープ（リール→チャックへ）
    d.polygon([(99, 74), (105, 78), (80, 92), (75, 87)], fill=reel_lt, outline=OUT)
    # チャック（格子 + チップ）
    rect(d, 38, 84, 44, 12, (190, 198, 210))
    for gx in range(48, 82, 10):
        d.line([(gx, 85), (gx, 95)], fill=DARK)
    d.line([(39, 90), (81, 90)], fill=DARK)
    for chx, chy in ((45, 86), (59, 89), (69, 86)):
        rect(d, chx, chy, 5, 5, GOLD)
    # ボンダーアーム + ヘッド
    rect(d, 26, 42, 44, 8, BODY)
    rect(d, 62, 50, 12, 14, MID)
    d.line([(68, 64), (68, 72)], fill=DEEP)
    d.point((68, 74), fill=GOLD)
    # 前面: 帯・窓・パネル
    rect(d, 13, 108, 118, 5, acc, outline=None)
    screen(d, 22, 118, 26, 17, acc)
    rect(d, 88, 116, 36, 22, MID)
    rect(d, 93, 121, 26, 4, DARK, outline=None)
    buttons(d, 94, 129)
    sparkle(d, 16, 22, 2)
    return finish(img, shad)


MAKERS = {
    "c1": draw_c1, "l1": draw_l1, "d1": draw_d1, "e1": draw_e1,
    "i1": draw_i1, "q1": draw_q1, "p1": draw_p1,
}


def main():
    gen_dir = os.path.join(ROOT, "design", "sprites", "generated")
    for mid, fn in MAKERS.items():
        img = fn()
        name = f"eq_{mid}_front_body.png"
        for dest in (
            os.path.join(gen_dir, name),
            os.path.join(ROOT, "FabTycoon", "Assets.xcassets",
                         f"eq_{mid}_front_body.imageset", name),
        ):
            img.save(dest, optimize=True)
        print(f"{mid}: {img.size[0]}x{img.size[1]}  "
              f"{os.path.getsize(os.path.join(gen_dir, name))} bytes")


if __name__ == "__main__":
    main()
