#!/usr/bin/env python3
"""R3: 残り13機種の本体スプライトをドット絵で追加する（gate3-dot-log.md の様式を踏襲）。

方式・スタイル基準は make_dot_sprites.py と同一:
- ネイティブ解像度（最終の 1/4）で PIL 手続き描画 → 輪郭パス → ×4 NEAREST 拡大
- 輪郭 #222636、本体グレー5階調共通、アクセントは工程色1色、シグナルタワーは描かない
- キャンバス幅は 72dot/セル を基準にフットプリント幅から決め、drawScale と合わせて
  表示ドット径が初期7機種の主域（0.014〜0.018 セル/dot）に収まるようにする

出力: design/sprites/generated/eq_<id>_front_body.png（マスター）と
      FabTycoon/Assets.xcassets/eq_<id>_front_body.imageset/ へ同一バイトを配置。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_dot_sprites import (  # noqa: E402
    canvas, shadow, box3d, rect, ell, disk, foup_slot, screen, buttons,
    sparkle, finish, OUT, HI, BODY, MID, DARK, DEEP, GLASS, GLASS_HI,
    FOUP, FOUP_D, GOLD, WHITE,
)
from PIL import ImageDraw  # noqa: E402  (多角形などの直接描画用に型だけ参照)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

ACCENT = {
    "l2": (255, 149, 0), "l3": (255, 149, 0), "l4": (255, 149, 0),   # 露光 orange
    "d2": (45, 180, 190), "d3": (45, 180, 190),                      # 成膜 teal
    "e2": (168, 92, 210), "e3": (168, 92, 210),                      # エッチ purple
    "i2": (52, 199, 89),                                             # 注入 green
    "c2": (56, 132, 255),                                            # CMP blue
    "q2": (88, 86, 214), "q3": (88, 86, 214),                        # 検査 indigo
    "p2": (162, 132, 94), "p3": (162, 132, 94),                      # PKG brown
}

WATER = (90, 170, 240)
LASER = (255, 60, 60)


# ---------------------------------------------------------------- L2 ArF液浸
def draw_l2():
    W, H = 288, 216
    img, d = canvas(W, H)
    shad = shadow(img, (10, 196, 278, 212))
    acc = ACCENT["l2"]
    # 本体キャビネット
    box3d(d, 30, 128, 150, 76, dep=6)
    # レンズ塔
    box3d(d, 66, 52, 54, 78, dep=5)
    box3d(d, 58, 40, 70, 14, dep=5, front=MID, top=HI)
    disk(d, 93, 88, 17, DARK)
    disk(d, 93, 88, 12, (104, 96, 220), outline=None)
    disk(d, 93, 88, 7, (150, 140, 245), outline=None)
    disk(d, 93, 88, 2, WHITE, outline=None)
    d.point((87, 81), fill=GLASS_HI)
    # 液浸フード＋ステージ
    rect(d, 74, 106, 38, 9, MID)
    rect(d, 50, 116, 88, 12, MID)
    ell(d, 93, 121, 24, 5, (203, 211, 224))
    rect(d, 66, 126, 54, 3, acc, outline=None)
    # 右の液浸ユニット（水タンク）
    box3d(d, 186, 84, 72, 120, dep=6)
    rect(d, 168, 96, 18, 10, DARK)
    rect(d, 196, 100, 44, 54, WATER)
    d.line([(197, 112), (239, 112)], fill=GLASS_HI, width=2)
    d.line([(197, 140), (239, 140)], fill=(60, 130, 210), width=2)
    screen(d, 196, 164, 40, 26, acc)
    buttons(d, 246, 168)
    # 前面: 帯＋FOUP×3
    rect(d, 31, 138, 148, 6, acc, outline=None)
    foup_slot(d, 40, 166, 34, 34)
    foup_slot(d, 82, 166, 34, 34)
    foup_slot(d, 124, 166, 34, 34)
    sparkle(d, 276, 30)
    sparkle(d, 16, 60, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- L3 EUV
def draw_l3():
    W, H = 360, 252
    img, d = canvas(W, H)
    shad = shadow(img, (8, 232, 352, 248))
    acc = ACCENT["l3"]
    # 光源容器（右の円筒）
    rect(d, 252, 120, 64, 122, BODY)
    ell(d, 284, 120, 32, 10, HI)
    rect(d, 253, 150, 62, 8, acc, outline=None)
    disk(d, 284, 192, 16, MID)
    disk(d, 284, 192, 9, acc, outline=None)
    disk(d, 284, 192, 3, DEEP, outline=None)
    # ドライブレーザー箱（容器の上）
    rect(d, 268, 84, 72, 36, MID)
    screen(d, 276, 92, 30, 18, acc)
    rect(d, 314, 94, 18, 6, DARK, outline=None)
    rect(d, 314, 104, 18, 6, DARK, outline=None)
    rect(d, 240, 108, 14, 44, DARK)
    # 本体キャビネット
    box3d(d, 24, 150, 216, 92, dep=7)
    # 上部のミラー筐体
    box3d(d, 48, 108, 120, 44, dep=6, front=MID, top=HI)
    rect(d, 60, 124, 80, 10, GLASS)
    d.line([(64, 132), (100, 126)], fill=GLASS_HI, width=2)
    # ステージ＋ウエハ
    rect(d, 36, 138, 180, 12, MID)
    ell(d, 120, 144, 30, 6, (203, 211, 224))
    sparkle(d, 120, 128, 4)
    # 前面: 帯・画面・ゲージ・FOUP×4
    rect(d, 25, 162, 214, 6, acc, outline=None)
    screen(d, 36, 172, 44, 22, acc)
    for gx in (196, 220):
        disk(d, gx, 183, 6, WHITE)
        d.point((gx, 180), fill=DEEP)
    foup_slot(d, 36, 200, 40, 36)
    foup_slot(d, 88, 200, 40, 36)
    foup_slot(d, 140, 200, 40, 36)
    foup_slot(d, 192, 200, 40, 36)
    sparkle(d, 344, 40, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- L4 High-NA EUV
def draw_l4():
    W, H = 432, 264
    img, d = canvas(W, H)
    shad = shadow(img, (8, 244, 424, 260))
    acc = ACCENT["l4"]
    # 上部のミラー筐体（全幅）とポッド
    box3d(d, 96, 72, 54, 26, dep=5)
    box3d(d, 282, 72, 54, 26, dep=5)
    box3d(d, 60, 96, 312, 34, dep=6, front=MID, top=HI)
    rect(d, 84, 108, 110, 10, GLASS)
    rect(d, 238, 108, 110, 10, GLASS)
    rect(d, 100, 130, 14, 28, DARK)
    rect(d, 318, 130, 14, 28, DARK)
    # 左右キャビネット
    box3d(d, 20, 158, 168, 94, dep=7)
    box3d(d, 244, 158, 168, 94, dep=7)
    # 中央の光源容器
    rect(d, 192, 128, 48, 124, BODY)
    ell(d, 216, 128, 24, 8, HI)
    rect(d, 193, 158, 46, 7, acc, outline=None)
    disk(d, 216, 200, 12, MID)
    disk(d, 216, 200, 6, acc, outline=None)
    sparkle(d, 216, 108, 4)
    # 前面: 帯・画面・FOUP×4（左右2ずつ）
    rect(d, 21, 196, 166, 5, acc, outline=None)
    rect(d, 245, 196, 166, 5, acc, outline=None)
    screen(d, 140, 166, 38, 24, acc)
    screen(d, 352, 166, 38, 24, acc)
    foup_slot(d, 32, 204, 40, 38)
    foup_slot(d, 84, 204, 40, 38)
    foup_slot(d, 256, 204, 40, 38)
    foup_slot(d, 308, 204, 40, 38)
    buttons(d, 366, 206)
    sparkle(d, 420, 36, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- D2 ALD/CVDクラスタ
def draw_d2():
    W, H = 216, 204
    img, d = canvas(W, H)
    shad = shadow(img, (8, 186, 208, 200))
    acc = ACCENT["d2"]
    # プラットフォーム
    box3d(d, 20, 140, 176, 54, dep=6)
    # 接続パイプ
    rect(d, 52, 100, 14, 8, DARK)
    rect(d, 150, 100, 14, 8, DARK)
    rect(d, 100, 62, 16, 10, DARK)
    rect(d, 61, 64, 10, 16, DARK)
    rect(d, 145, 64, 10, 16, DARK)
    # サテライトポッド×4
    for cx, cy, r in ((44, 112, 13), (172, 112, 13), (66, 56, 11), (150, 56, 11)):
        rect(d, cx - r + 1, cy - 4, (r - 1) * 2, 24 if r == 13 else 20, BODY)
        ell(d, cx, cy - 4, r, r // 2 + 2, HI)
        ell(d, cx, cy - 4, r // 2, (r // 2) // 2 + 1, acc, outline=None)
    # 中央チャンバー（八角形）
    import math
    cx, cy, r = 108, 106, 38
    pts = []
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a) * 0.92))
    d.polygon(pts, fill=BODY, outline=OUT)
    ell(d, 108, 92, 24, 10, HI)
    ell(d, 108, 92, 15, 6, acc, outline=None)
    disk(d, 108, 92, 3, DEEP, outline=None)
    # 前面: 帯＋FOUP×3
    rect(d, 21, 146, 174, 5, acc, outline=None)
    foup_slot(d, 32, 158, 36, 32)
    foup_slot(d, 90, 158, 36, 32)
    foup_slot(d, 148, 158, 36, 32)
    sparkle(d, 200, 24, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- D3 先端ALD
def draw_d3():
    W, H = 216, 180
    img, d = canvas(W, H)
    shad = shadow(img, (8, 162, 208, 176))
    acc = ACCENT["d3"]
    # 前駆体キャニスタ塔（中央背面）
    rect(d, 98, 36, 20, 56, MID)
    rect(d, 92, 24, 8, 14, DARK)
    rect(d, 104, 20, 8, 18, DARK)
    rect(d, 116, 24, 8, 14, DARK)
    # 接続パイプ
    rect(d, 58, 94, 100, 6, DARK)
    # ツインチャンバー
    for cx in (64, 152):
        rect(d, cx - 21, 84, 42, 26, BODY)
        ell(d, cx, 84, 21, 7, HI)
        ell(d, cx, 84, 10, 3, acc, outline=None)
    # 本体キャビネット
    box3d(d, 24, 106, 168, 64, dep=6)
    rect(d, 25, 114, 166, 5, acc, outline=None)
    screen(d, 34, 126, 36, 24, acc)
    foup_slot(d, 84, 128, 40, 36)
    foup_slot(d, 136, 128, 40, 36)
    sparkle(d, 200, 16, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- E2 高選択比エッチャ
def draw_e2():
    W, H = 216, 228
    img, d = canvas(W, H)
    shad = shadow(img, (10, 208, 206, 224))
    acc = ACCENT["e2"]
    # スクラバー（左円筒）とパイプ
    rect(d, 58, 72, 92, 9, BODY)
    rect(d, 28, 66, 30, 52, BODY)
    ell(d, 43, 66, 15, 7, HI)
    rect(d, 29, 84, 28, 6, acc, outline=None)
    # 排気ダクト
    rect(d, 150, 20, 22, 98, BODY)
    for yy in range(32, 116, 14):
        d.line([(151, yy), (171, yy)], fill=DARK)
    rect(d, 143, 12, 36, 8, MID)
    rect(d, 144, 64, 34, 6, MID)
    rect(d, 142, 40, 38, 24, MID)
    disk(d, 161, 52, 7, DARK)
    disk(d, 161, 52, 2, DEEP, outline=None)
    # 本体
    box3d(d, 22, 118, 172, 100, dep=6)
    rect(d, 23, 126, 170, 5, acc, outline=None)
    # ツインチャンバードア
    for cx in (70, 140):
        disk(d, cx, 160, 26, HI)
        disk(d, cx, 160, 19, acc, outline=None)
        disk(d, cx, 160, 11, (150, 110, 220), outline=None)
        d.point((cx - 6, 153), fill=GLASS_HI)
        for k in range(6):
            import math
            a = math.radians(60 * k + 30)
            d.point((cx + 23 * math.cos(a), 160 + 23 * math.sin(a)), fill=DEEP)
    screen(d, 168, 134, 20, 14, acc)
    # FOUP×2
    foup_slot(d, 52, 192, 30, 24)
    foup_slot(d, 120, 192, 30, 24)
    sparkle(d, 16, 24, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- E3 原子層エッチャ（ALE）
def draw_e3():
    W, H = 216, 204
    img, d = canvas(W, H)
    shad = shadow(img, (10, 186, 206, 200))
    acc = ACCENT["e3"]
    # 細い排気ダクト
    rect(d, 88, 18, 16, 80, BODY)
    for yy in range(30, 96, 16):
        d.line([(89, yy), (103, yy)], fill=DARK)
    rect(d, 82, 10, 28, 8, MID)
    # ガスキャビネット（左）
    rect(d, 16, 110, 30, 84, BODY)
    ell(d, 31, 110, 15, 6, HI)
    disk(d, 31, 128, 6, WHITE)
    disk(d, 31, 146, 6, WHITE)
    d.point((31, 125), fill=DEEP)
    d.point((31, 143), fill=DEEP)
    rect(d, 17, 160, 28, 5, acc, outline=None)
    foup_slot(d, 19, 168, 24, 22)
    rect(d, 46, 120, 8, 10, DARK)
    # 本体（スリム）
    box3d(d, 52, 96, 112, 98, dep=6)
    # 大型ガラスドア（矩形）
    rect(d, 64, 108, 68, 56, (178, 140, 228))
    d.line([(70, 158), (104, 114)], fill=GLASS_HI, width=2)
    rect(d, 124, 130, 4, 16, DEEP, outline=None)
    disk(d, 84, 122, 3, WHITE, outline=None)
    # FOUP×2（本体前面下）
    foup_slot(d, 60, 170, 32, 22)
    foup_slot(d, 100, 170, 32, 22)
    sparkle(d, 196, 30, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- I2 高エネルギー注入＋レーザーアニール
def draw_i2():
    W, H = 288, 120
    img, d = canvas(W, H)
    shad = shadow(img, (4, 104, 284, 116))
    acc = ACCENT["i2"]
    # 脚
    for lx in (80, 140, 200):
        rect(d, lx, 88, 6, 14, DARK)
    # ビームチューブ
    rect(d, 66, 52, 166, 18, BODY)
    d.line([(67, 56), (231, 56)], fill=HI)
    d.line([(67, 65), (231, 65)], fill=MID)
    for rx in (96, 128, 208):
        rect(d, rx, 49, 6, 24, MID)
    for px in (108, 176):
        rect(d, px, 40, 16, 12, MID)
        rect(d, px + 5, 36, 6, 4, DARK)
    for vx in (112, 200):
        disk(d, vx, 61, 3, (140, 240, 170))
    # イオン源キャビネット（左）
    box3d(d, 8, 30, 54, 72, dep=5)
    screen(d, 16, 40, 22, 16, acc)
    rect(d, 9, 66, 52, 5, acc, outline=None)
    buttons(d, 42, 42)
    foup_slot(d, 16, 76, 30, 22)
    # 偏向マグネット
    box3d(d, 140, 36, 44, 66, dep=5, front=MID, top=HI)
    rect(d, 141, 58, 42, 6, acc, outline=None)
    disk(d, 162, 84, 5, DEEP)
    # レーザーアニールキャビネット（右・高め）
    box3d(d, 232, 16, 50, 86, dep=5)
    d.polygon([(248, 44), (266, 44), (257, 28)], fill=(250, 200, 70), outline=OUT)
    d.point((257, 38), fill=DEEP)
    rect(d, 240, 52, 34, 20, GLASS)
    rect(d, 242, 61, 30, 2, LASER, outline=None)
    rect(d, 233, 80, 48, 5, acc, outline=None)
    sparkle(d, 282, 8, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- C2 先端CMP
def draw_c2():
    W, H = 216, 176
    img, d = canvas(W, H)
    shad = shadow(img, (10, 158, 206, 172))
    acc = ACCENT["c2"]
    light = (96, 155, 235)
    # 筐体
    box3d(d, 28, 104, 160, 62, dep=6)
    rect(d, 20, 94, 176, 10, MID)
    # 上部バー＋研磨ヘッド×2
    rect(d, 52, 38, 120, 8, BODY)
    for hx in (58, 150):
        rect(d, hx, 46, 8, 26, MID)
        ell(d, hx + 6, 74, 12, 6, DEEP)
        ell(d, hx + 6, 71, 12, 6, HI)
    # デュアルプラテン
    for cx in (72, 144):
        ell(d, cx, 84, 34, 13, DARK)
        ell(d, cx, 84, 30, 11, acc, outline=None)
        ell(d, cx, 84, 21, 8, light, outline=None)
        ell(d, cx, 84, 12, 4, acc, outline=None)
        disk(d, cx, 84, 3, HI)
    # コンディショナ
    ell(d, 30, 88, 9, 4, DARK)
    ell(d, 30, 87, 7, 3, MID, outline=None)
    # 前面: 帯・画面・FOUP×2
    rect(d, 29, 112, 158, 5, acc, outline=None)
    screen(d, 36, 122, 26, 18, acc)
    foup_slot(d, 76, 124, 34, 36)
    foup_slot(d, 122, 124, 34, 36)
    sparkle(d, 202, 20, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- Q2 電子ビーム検査
def draw_q2():
    W, H = 144, 248
    img, d = canvas(W, H)
    shad = shadow(img, (20, 230, 124, 244))
    acc = ACCENT["q2"]
    # 電子銃（上部のコーン＋キャップ）
    rect(d, 66, 20, 12, 10, MID)
    disk(d, 72, 14, 4, acc)
    d.polygon([(64, 54), (80, 54), (76, 30), (68, 30)], fill=DARK, outline=OUT)
    # コラム
    rect(d, 58, 54, 28, 96, BODY)
    d.line([(64, 56), (64, 148)], fill=MID)
    d.line([(80, 56), (80, 148)], fill=MID)
    rect(d, 58, 84, 28, 4, MID, outline=None)
    rect(d, 58, 120, 28, 4, MID, outline=None)
    # モニターアーム＋モニター
    rect(d, 86, 90, 12, 5, MID)
    box3d(d, 98, 76, 36, 28, dep=3)
    screen(d, 103, 81, 26, 18, acc)
    # ヘッド＋対物コーン
    box3d(d, 44, 146, 56, 24, dep=4)
    rect(d, 45, 164, 54, 4, acc, outline=None)
    d.polygon([(62, 170), (82, 170), (76, 184), (68, 184)], fill=DARK, outline=OUT)
    d.point((72, 186), fill=acc)
    # ステージハウジング
    box3d(d, 38, 186, 68, 26, dep=4)
    ell(d, 72, 185, 22, 6, MID)
    ell(d, 72, 184, 15, 4, (203, 211, 224))
    # ベースキャビネット＋FOUP×2
    box3d(d, 26, 210, 92, 32, dep=5)
    foup_slot(d, 32, 215, 26, 23)
    screen(d, 95, 215, 19, 15, acc)
    foup_slot(d, 62, 215, 26, 23)
    sparkle(d, 132, 24, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- Q3 AI欠陥分類検査
def draw_q3():
    W, H = 144, 196
    img, d = canvas(W, H)
    shad = shadow(img, (18, 178, 126, 192))
    acc = ACCENT["q3"]
    # 大型モニター（チャート表示）
    box3d(d, 64, 52, 68, 52, dep=4)
    rect(d, 70, 58, 56, 34, GLASS)
    for i, bh in enumerate((10, 18, 7, 22, 13)):
        rect(d, 75 + i * 10, 92 - bh, 6, bh, acc if i % 2 == 0 else (90, 210, 120), outline=None)
    d.line([(72, 66), (88, 62), (102, 70), (124, 60)], fill=(255, 120, 120), width=1)
    rect(d, 94, 104, 8, 20, MID)
    # サーバーラック（右下）
    rect(d, 78, 124, 54, 58, MID)
    rect(d, 79, 130, 52, 4, acc, outline=None)
    for r in range(4):
        for c in range(4):
            col = (90, 210, 120) if (r + c) % 3 else WHITE
            rect(d, 84 + c * 12, 140 + r * 10, 4, 4, col, outline=None)
        rect(d, 84, 146 + r * 10, 44, 1, DARK, outline=None)
    # 細いコラム（左）
    box3d(d, 22, 28, 34, 20, dep=3)
    rect(d, 30, 44, 18, 100, BODY)
    rect(d, 31, 40, 16, 4, acc, outline=None)
    d.polygon([(32, 144), (46, 144), (42, 154), (36, 154)], fill=DARK, outline=OUT)
    d.point((39, 156), fill=acc)
    # ベース＋ステージ
    box3d(d, 14, 166, 58, 24, dep=4)
    box3d(d, 16, 148, 52, 20, dep=4)
    ell(d, 42, 147, 16, 4, (203, 211, 224))
    foup_slot(d, 20, 171, 20, 16)
    foup_slot(d, 46, 171, 20, 16)
    sparkle(d, 136, 20, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- P2 レーザーダイシング＋フリップチップ
def draw_p2():
    W, H = 216, 176
    img, d = canvas(W, H)
    shad = shadow(img, (8, 158, 208, 172))
    acc = ACCENT["p2"]
    # キャビネット＋テーブル
    box3d(d, 16, 108, 184, 58, dep=6)
    rect(d, 24, 98, 168, 10, MID)
    # ガントリー（支柱＋ビーム＋レーザーヘッド）
    rect(d, 36, 48, 8, 52, BODY)
    rect(d, 172, 48, 8, 52, BODY)
    rect(d, 36, 42, 144, 10, BODY)
    rect(d, 96, 52, 24, 20, MID)
    d.polygon([(102, 72), (114, 72), (110, 82), (106, 82)], fill=DARK, outline=OUT)
    rect(d, 107, 82, 2, 14, LASER, outline=None)
    disk(d, 108, 98, 2, GOLD, outline=None)
    # ウエハチャック
    ell(d, 70, 100, 24, 5, (203, 211, 224))
    d.line([(52, 100), (88, 100)], fill=DARK)
    # フリップチップアーム
    rect(d, 140, 60, 7, 40, BODY)
    rect(d, 140, 58, 36, 7, BODY)
    rect(d, 168, 65, 10, 12, MID)
    rect(d, 170, 79, 6, 5, GOLD, outline=None)
    # チップトレイ
    rect(d, 120, 92, 44, 10, (190, 198, 210))
    for tx in (126, 138, 150):
        rect(d, tx, 95, 6, 5, GOLD, outline=None)
    # 前面: 帯・画面・FOUP×2・ボタン
    rect(d, 17, 116, 182, 5, acc, outline=None)
    screen(d, 26, 126, 28, 20, acc)
    foup_slot(d, 70, 128, 36, 32)
    foup_slot(d, 118, 128, 36, 32)
    buttons(d, 168, 130)
    sparkle(d, 204, 18, 2)
    return finish(img, shad)


# ---------------------------------------------------------------- P3 先端パッケージ（2.5D/チップレット）
def draw_p3():
    W, H = 216, 196
    img, d = canvas(W, H)
    shad = shadow(img, (8, 178, 208, 192))
    acc = ACCENT["p3"]
    # プラットフォーム
    box3d(d, 18, 132, 180, 54, dep=6)
    # ボンダー本体（左上）
    box3d(d, 28, 72, 74, 62, dep=5)
    rect(d, 28, 58, 74, 10, MID)
    disk(d, 40, 63, 2, acc, outline=None)
    disk(d, 52, 63, 2, acc, outline=None)
    screen(d, 36, 82, 24, 16, acc)
    rect(d, 88, 84, 30, 8, BODY)
    rect(d, 112, 92, 12, 16, MID)
    rect(d, 115, 110, 6, 5, GOLD, outline=None)
    # インターポーザーステーション（中央）
    rect(d, 108, 112, 52, 10, MID)
    ell(d, 134, 110, 24, 6, (203, 211, 224))
    for gx, gy in ((124, 107), (136, 106), (130, 112), (142, 111)):
        rect(d, gx, gy, 5, 4, GOLD, outline=None)
    # 右ユニット（オーブン）
    box3d(d, 158, 84, 44, 50, dep=5)
    rect(d, 166, 96, 28, 24, GLASS)
    d.line([(169, 116), (182, 100)], fill=GLASS_HI, width=2)
    rect(d, 159, 124, 42, 5, acc, outline=None)
    # 前面: 帯＋FOUP×3
    rect(d, 19, 140, 178, 5, acc, outline=None)
    foup_slot(d, 28, 152, 36, 30)
    foup_slot(d, 90, 152, 36, 30)
    foup_slot(d, 152, 152, 36, 30)
    sparkle(d, 204, 30, 2)
    sparkle(d, 12, 52, 2)
    return finish(img, shad)


MAKERS = {
    "l2": draw_l2, "l3": draw_l3, "l4": draw_l4,
    "d2": draw_d2, "d3": draw_d3,
    "e2": draw_e2, "e3": draw_e3,
    "i2": draw_i2, "c2": draw_c2,
    "q2": draw_q2, "q3": draw_q3,
    "p2": draw_p2, "p3": draw_p3,
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
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            img.save(dest, optimize=True)
        print(f"{mid}: {img.size[0]}x{img.size[1]}  "
              f"{os.path.getsize(os.path.join(gen_dir, name))} bytes")


if __name__ == "__main__":
    main()
