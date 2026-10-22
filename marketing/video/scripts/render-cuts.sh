#!/bin/bash
# Renders the README teaser (silent loop: MP4 + animated WebP + GIF) and the 9:16 social cut.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
[ -f out/teaser-raw.mp4 ] || npx remotion render src/index.ts Teaser out/teaser-raw.mp4 --codec h264 --crf 14 --muted --log=error
# README loop: 1280x720 MP4 (30 fps), animated WebP and GIF at 800 px.
ffmpeg -loglevel error -y -i out/teaser-raw.mp4 -vf "fps=30,scale=1280:-2:flags=lanczos" -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -an -movflags +faststart out/clementine-teaser.mp4
# Animated WebP via libwebp's img2webp (Homebrew's ffmpeg has no libwebp encoder): 20 fps = 50 ms per frame.
tmp=$(mktemp -d); ffmpeg -loglevel error -y -i out/teaser-raw.mp4 -vf "fps=20,scale=800:-2:flags=lanczos" "$tmp/f%04d.png"
img2webp -loop 0 -lossy -q 70 -m 6 -d 50 "$tmp"/f*.png -o out/clementine-teaser.webp >/dev/null; rm -rf "$tmp"
# GIF at 640 px / 12 fps / 128 colours with ordered dithering (compresses far better than error diffusion): < 5 MB.
ffmpeg -loglevel error -y -i out/teaser-raw.mp4 -vf "fps=12,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" -loop 0 out/clementine-teaser.gif
# 9:16 social cut: Remotion renders only the text layer (brand, live captions) with alpha; ffmpeg puts it over a
# blurred and a sharp copy of the finished film. Rendering <Launch> twice inside Remotion stalls the renderer.
npx remotion render src/index.ts SocialOverlay out/social-overlay.mov --codec prores --prores-profile 4444 --pixel-format yuva444p10le --image-format png --concurrency 6 --timeout 60000 --log=error
ffmpeg -loglevel error -y -i out/clementine-launch.mp4 -i out/social-overlay.mov -filter_complex "[0:v]fps=30,split[a][b];[a]scale=-2:1920,crop=1080:1920,gblur=sigma=40,eq=brightness=-0.16:saturation=1.2,colorlevels=romax=0.6:gomax=0.6:bomax=0.6[bg];[b]scale=1080:-2:flags=lanczos[fg];[bg][fg]overlay=0:560[base];[base][1:v]overlay=0:0:format=auto,format=yuv420p[v]" -map "[v]" -map 0:a -c:v libx264 -crf 19 -preset slow -c:a copy -movflags +faststart -shortest out/clementine-launch-9x16.mp4
ls -la out/*.mp4 out/*.webp out/*.gif
