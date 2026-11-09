#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
campaign_dir="$repo_root/Docs/Marketing/Ads/LaunchCampaign"
video_dir="$campaign_dir/Video"
raw_dir="$video_dir/Raw"
work_dir="$video_dir/Work"
output="$video_dir/oneway-launch-vertical-15s.mp4"
ffmpeg_bin="${FFMPEG_BIN:-ffmpeg}"
font_file="/System/Library/Fonts/SFNS.ttf"

mkdir -p "$work_dir"

voice_text="Your phone does a lot. OneWay does it together. Talk privately. Build your world. Shop unique. Belong anywhere. Download OneWay."
say -v Samantha -r 150 -o "$work_dir/voiceover.aiff" "$voice_text"

"$ffmpeg_bin" -y \
  -loop 1 -t 2 -i "$campaign_dir/oneway-launch-vertical-9x16.png" \
  -i "$raw_dir/oneway-quantum-clean.mov" \
  -loop 1 -t 3 -i "$raw_dir/oneway-calls-screen.png" \
  -loop 1 -t 3 -i "$repo_root/Docs/VisualQA/ShopsReference/shops-home-iphone17.png" \
  -loop 1 -t 4 -i "$campaign_dir/oneway-launch-vertical-9x16.png" \
  -i "$work_dir/voiceover.aiff" \
  -f lavfi -t 15 -i "sine=frequency=110:sample_rate=48000" \
  -f lavfi -t 15 -i "sine=frequency=164.81:sample_rate=48000" \
  -filter_complex "\
    [0:v]scale=1080:1920,setsar=1,fps=30,trim=duration=2,setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.25,fade=t=out:st=1.75:d=0.25[v0];\
    [1:v]scale=-2:1920,pad=1080:1920:(ow-iw)/2:0:color=0x05030d,setsar=1,fps=30,trim=duration=3,setpts=PTS-STARTPTS,\
      drawbox=x=0:y=0:w=iw:h=190:color=black@0.62:t=fill,\
      drawtext=fontfile='$font_file':text='TALK.':fontcolor=white:fontsize=92:x=(w-text_w)/2:y=55,\
      fade=t=in:st=0:d=0.18,fade=t=out:st=2.82:d=0.18[v1];\
    [2:v]scale=-2:1920,pad=1080:1920:(ow-iw)/2:0:color=0x05030d,setsar=1,fps=30,\
      zoompan=z='min(zoom+0.00045,1.035)':d=1:s=1080x1920:fps=30,trim=duration=3,setpts=PTS-STARTPTS,\
      drawbox=x=0:y=0:w=iw:h=190:color=black@0.62:t=fill,\
      drawtext=fontfile='$font_file':text='CONNECT.':fontcolor=white:fontsize=92:x=(w-text_w)/2:y=55,\
      fade=t=in:st=0:d=0.18,fade=t=out:st=2.82:d=0.18[v2];\
    [3:v]scale=-2:1920,pad=1080:1920:(ow-iw)/2:0:color=0x05030d,setsar=1,fps=30,\
      zoompan=z='min(zoom+0.00045,1.035)':d=1:s=1080x1920:fps=30,trim=duration=3,setpts=PTS-STARTPTS,\
      drawbox=x=0:y=0:w=iw:h=190:color=black@0.62:t=fill,\
      drawtext=fontfile='$font_file':text='SELL.':fontcolor=white:fontsize=92:x=(w-text_w)/2:y=55,\
      fade=t=in:st=0:d=0.18,fade=t=out:st=2.82:d=0.18[v3];\
    [4:v]scale=1080:1920,setsar=1,fps=30,trim=duration=4,setpts=PTS-STARTPTS,fade=t=in:st=0:d=0.25[v4];\
    [v0][v1][v2][v3][v4]concat=n=5:v=1:a=0,tpad=stop_mode=clone:stop_duration=4,trim=duration=15,setpts=PTS-STARTPTS,format=yuv420p[v];\
    [5:a]aformat=sample_rates=48000:channel_layouts=stereo,volume=1.25,adelay=350|350[voice];\
    [6:a]volume=0.025,lowpass=f=260,afade=t=in:st=0:d=1.2,afade=t=out:st=13:d=2[m1];\
    [7:a]volume=0.016,lowpass=f=320,afade=t=in:st=0:d=1.2,afade=t=out:st=13:d=2[m2];\
    [voice][m1][m2]amix=inputs=3:duration=longest:normalize=0,alimiter=limit=0.92[a]" \
  -map "[v]" -map "[a]" \
  -t 15 -r 30 -c:v libx264 -preset medium -crf 18 -profile:v high -level 4.1 \
  -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$output"

echo "$output"
