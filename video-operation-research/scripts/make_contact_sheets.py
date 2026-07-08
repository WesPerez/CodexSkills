#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从本地视频生成总览拼图和可选裁剪拼图。"""

import argparse
import json
import math
import os
from pathlib import Path

import cv2
from PIL import Image, ImageDraw


def parse_times(value):
    if not value:
        return None
    result = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            pieces = [int(p) for p in part.split(":")]
            if len(pieces) == 2:
                result.append(pieces[0] * 60 + pieces[1])
            elif len(pieces) == 3:
                result.append(pieces[0] * 3600 + pieces[1] * 60 + pieces[2])
            else:
                raise ValueError(f"时间格式错误: {part}")
        else:
            result.append(float(part))
    return result


def parse_crop(value, width, height):
    if not value:
        return None
    value = value.strip().lower()
    if value.startswith("bottom:"):
        ratio = float(value.split(":", 1)[1])
        crop_h = int(height * ratio)
        return (0, max(0, height - crop_h), width, height)
    parts = [int(p.strip()) for p in value.split(",")]
    if len(parts) != 4:
        raise ValueError("裁剪参数必须是 'bottom:0.28' 或 'x1,y1,x2,y2'")
    x1, y1, x2, y2 = parts
    return (max(0, x1), max(0, y1), min(width, x2), min(height, y2))


def label_image(img, label, thumb_width):
    img = img.copy()
    img.thumbnail((thumb_width, int(thumb_width * 9 / 16)), Image.LANCZOS)
    canvas = Image.new("RGB", (thumb_width, img.height + 26), "white")
    canvas.paste(img, ((thumb_width - img.width) // 2, 0))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([0, img.height, thumb_width, img.height + 26], fill=(0, 0, 0))
    draw.text((8, img.height + 6), label, fill="white")
    return canvas


def save_sheets(items, out_dir, prefix, columns):
    if not items:
        return []
    paths = []
    first = items[0][1]
    rows_per_sheet = 6
    per_sheet = columns * rows_per_sheet
    for sheet_index, start in enumerate(range(0, len(items), per_sheet), 1):
        chunk = items[start : start + per_sheet]
        rows = math.ceil(len(chunk) / columns)
        sheet = Image.new(
            "RGB",
            (columns * first.width, rows * first.height),
            (240, 240, 240),
        )
        for i, (_, image) in enumerate(chunk):
            sheet.paste(image, ((i % columns) * first.width, (i // columns) * first.height))
        path = out_dir / f"{prefix}_{sheet_index:03d}.jpg"
        sheet.save(path, quality=92)
        paths.append(str(path))
    return paths


def main():
    parser = argparse.ArgumentParser(
        description="从本地视频生成总览拼图和可选裁剪拼图。",
        add_help=False,
    )
    parser._optionals.title = "可选参数"
    parser.add_argument("-h", "--help", action="help", help="显示帮助并退出")
    parser.add_argument("--video", required=True, help="本地视频路径")
    parser.add_argument("--out", required=True, help="输出目录")
    parser.add_argument("--interval", type=float, default=5.0, help="抽样间隔，单位秒")
    parser.add_argument("--times", help="逗号分隔的秒数或 mm:ss 时间戳")
    parser.add_argument("--columns", type=int, default=4)
    parser.add_argument("--thumb-width", type=int, default=320)
    parser.add_argument(
        "--subtitle-crop",
        help="可选文字放大裁剪区域：bottom:0.28 或 x1,y1,x2,y2",
    )
    args = parser.parse_args()

    video_path = Path(args.video)
    out_dir = Path(args.out)
    frames_dir = out_dir / "frames"
    crops_dir = out_dir / "crops"
    out_dir.mkdir(parents=True, exist_ok=True)
    frames_dir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise SystemExit(f"无法打开视频: {video_path}")

    fps = float(cap.get(cv2.CAP_PROP_FPS) or 0)
    frame_count = float(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration = frame_count / fps if fps else 0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)

    times = parse_times(args.times)
    if times is None:
        end = max(0, int(math.floor(duration)))
        times = [t for t in frange(0, end, args.interval)]
    crop_box = parse_crop(args.subtitle_crop, width, height)
    if crop_box:
        crops_dir.mkdir(parents=True, exist_ok=True)

    frame_items = []
    crop_items = []
    samples = []
    for t in times:
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0, t) * 1000)
        ok, frame = cap.read()
        if not ok:
            samples.append({"time": t, "ok": False})
            continue
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        image = Image.fromarray(rgb)
        label = seconds_label(t)
        frame_path = frames_dir / f"frame_{int(round(t * 1000)):09d}.jpg"
        image.save(frame_path, quality=92)
        frame_items.append((t, label_image(image, label, args.thumb_width)))

        crop_path = None
        if crop_box:
            crop = image.crop(crop_box)
            crop = crop.resize((crop.width * 2, crop.height * 2), Image.LANCZOS)
            crop_path = crops_dir / f"crop_{int(round(t * 1000)):09d}.jpg"
            crop.save(crop_path, quality=92)
            crop_items.append((t, label_image(crop, label, args.thumb_width * 2)))

        samples.append(
            {
                "time": t,
                "label": label,
                "ok": True,
                "frame": str(frame_path),
                "crop": str(crop_path) if crop_path else None,
            }
        )

    cap.release()
    sheets = save_sheets(frame_items, out_dir, "contact_sheet", args.columns)
    crop_sheets = save_sheets(crop_items, out_dir, "crop_sheet", 2)
    manifest = {
        "video": str(video_path),
        "fps": fps,
        "frame_count": frame_count,
        "duration_seconds": duration,
        "width": width,
        "height": height,
        "interval": args.interval,
        "subtitle_crop": args.subtitle_crop,
        "contact_sheets": sheets,
        "crop_sheets": crop_sheets,
        "samples": samples,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps({"manifest": str(manifest_path), "sheets": sheets, "crop_sheets": crop_sheets}, indent=2))


def frange(start, stop, step):
    x = float(start)
    while x <= stop:
        yield round(x, 3)
        x += step


def seconds_label(seconds):
    seconds = int(round(seconds))
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


if __name__ == "__main__":
    main()
