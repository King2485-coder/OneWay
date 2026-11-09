#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
campaign_dir="$repo_root/Docs/Marketing/Ads/LaunchCampaign"
video_dir="$campaign_dir/Video"
raw_dir="$video_dir/Raw"
work_dir="$video_dir/Work"
output="$video_dir/oneway-launch-tv-15s.mp4"
ffmpeg_bin="${FFMPEG_BIN:-ffmpeg}"
font_file="/System/Library/Fonts/SFNS.ttf"

mkdir -p "$work_dir"

voice_text="Your phone does a lot. OneWay does it together. Talk privately. Build your world. Shop unique. Belong anywhere. Download OneWay."
say -v Samantha -r 150 -o "$work_dir/voiceover-tv.aiff" "$voice_text"

"$ffmpeg_bin" -y \
  -loop 1 -t 3 -i "$campaign_dir/oneway-launch-tv-16x9.png" \
  -f lavfi -t 8 -i "color=c=0x05030d:s=1920x1080:r=30" \
  -loop 1 -t 8 -i "$raw_dir/oneway-quantum-screen.png" \
  -loop 1 -t 8 -i "$raw_dir/oneway-calls-screen.png" \
  -loop 1 -t 8 -i "$repo_root/Docs/VisualQA/ShopsReference/shops-home-iphone17.png" \
  -loop 1 -t 4 -i "$campaign_dir/oneway-launch-tv-16x9.png" \
  -i "$work_dir/voiceover-tv.aiff" \
  -f lavfi -t 15 -i "sine=frequency=110:sample_rate=48000" \
  -f lavfi -t 15 -i "sine=frequency=164.81:sample_rate=48000" \
  -filter_complex "\
    [0:v]scale=1920:1080,setsar=1,fps=30,trim=duration=3,setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.25,fade=t=out:st=2.75:d=0.25[v0];\
    [1:v]format=rgba,\
      drawtext=fontfile='$font_file':text='TALK.  BUILD.  SELL.  BELONG.':fontcolor=white:fontsize=72:x=(w-text_w)/2:y=45,\
      drawbox=x=250:y=145:w=380:h=800:color=0x8d42ff@0.55:t=5,\
      drawbox=x=770:y=145:w=380:h=800:color=0x8d42ff@0.55:t=5,\
      drawbox=x=1290:y=145:w=380:h=800:color=0x8d42ff@0.55:t=5[base];\
    [2:v]scale=360:782,setsar=1,fps=30,trim=duration=8,setpts=PTS-STARTPTS[q];\
    [3:v]scale=360:782,setsar=1,fps=30,trim=duration=8,setpts=PTS-STARTPTS[c];\
    [4:v]scale=360:782,setsar=1,fps=30,trim=duration=8,setpts=PTS-STARTPTS[s];\
    [base][q]overlay=x=260:y=155[tmp1];\
    [tmp1][c]overlay=x=780:y=155[tmp2];\
    [tmp2][s]overlay=x=1300:y=155,\
      drawtext=fontfile='$font_file':text='QUANTUM':fontcolor=0xc394ff:fontsize=38:x=350:y=975,\
      drawtext=fontfile='$font_file':text='CALLS':fontcolor=0xc394ff:fontsize=38:x=900:y=975,\
      drawtext=fontfile='$font_file':text='SHOPS':fontcolor=0xc394ff:fontsize=38:x=1415:y=975,\
      trim=duration=8,setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.2,fade=t=out:st=7.8:d=0.2[v1];\
    [5:v]scale=1920:1080,setsar=1,fps=30,trim=duration=4,setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.25[v2];\
    [v0][v1][v2]concat=n=3:v=1:a=0,tpad=stop_mode=clone:stop_duration=3,trim=duration=15,setpts=PTS-STARTPTS,format=yuv420p[v];\
    [6:a]aformat=sample_rates=48000:channel_layouts=stereo,volume=1.25,adelay=350|350[voice];\
    [7:a]volume=0.025,lowpass=f=260,afade=t=in:st=0:d=1.2,afade=t=out:st=13:d=2[m1];\
    [8:a]volume=0.016,lowpass=f=320,afade=t=in:st=0:d=1.2,afade=t=out:st=13:d=2[m2];\
    [voice][m1][m2]amix=inputs=3:duration=longest:normalize=0,alimiter=limit=0.92[a]" \
  -map "[v]" -map "[a]" \
  -t 15 -r 30 -c:v libx264 -preset medium -crf 18 -profile:v high -level 4.1 \
  -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$output"

echo "$output"
