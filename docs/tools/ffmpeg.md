---
layout: default
title: ffmpeg
parent: Tools
nav_order: 19
---

# ffmpeg

Convert images to WebP format using ffmpeg.

## Usage

```
@ffmpeg input="<path>" [output="<path>"] [quality=80]
```

## Examples

- `@ffmpeg input="photo.png"` - Convert to photo.webp (quality: 80)
- `@ffmpeg input="photo.png" quality=60` - Lower quality for smaller size
- `@ffmpeg input="images/big.jpg" output="compressed.webp"` - Custom output name
- `@ffmpeg input="images/big.jpg" quality=90` - High quality

## Parameters

| Parameter | Type    | Description                                                        |
| --------- | ------- | ------------------------------------------------------------------ |
| `input`   | string  | **Required**. Source image file path (relative to cwd or absolute) |
| `output`  | string  | Output webp path (default: same name with `.webp` extension)       |
| `quality` | integer | WebP quality 0-100, higher = better quality (default: 80)          |

## Supported Input Formats

PNG, JPG, JPEG, BMP, GIF, TIFF, TGA, WebP

## Notes

{: .info }
> - Requires ffmpeg to be installed with libwebp encoder
> - Install ffmpeg: [https://ffmpeg.org/download.html](https://ffmpeg.org/download.html)
> - Input and output paths must be within working directory (cwd) and allowed_path config

