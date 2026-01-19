#!/bin/bash

# ==============================================================================
#  MATH-BASED ENCODER: Accurate Metrics for TS Files
# ==============================================================================

if [ -z "$1" ]; then
    echo "Usage: ./encode.sh <input_video.mp4>"
    exit 1
fi

# 1. إعداد المسارات
INPUT_FILE=$(realpath "$1")
FILENAME=$(basename -- "$INPUT_FILE")
BASENAME="${FILENAME%.*}"

CURRENT_DIR=$(pwd)
OUTPUT_FOLDER_NAME="results_${BASENAME}"
OUTPUT_DIR="${CURRENT_DIR}/${OUTPUT_FOLDER_NAME}"
REPORT_FILE="$OUTPUT_DIR/REPORT_METRICS.txt"

# التأكد من الأدوات
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' is required."; exit 1; }

echo "--------------------------------------------------------"
echo ">> [INIT] Input:  $FILENAME"
echo ">> [INIT] Output: $OUTPUT_DIR"
echo "--------------------------------------------------------"

mkdir -p "$OUTPUT_DIR"

# دالة حساب آمنة
calc() { awk "BEGIN { print $* }" 2>/dev/null || echo "0"; }

# تحليل المصدر
echo ">> [1/3] Analyzing Source..."
SRC_SIZE=$(stat --printf="%s" "$INPUT_FILE")
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")
if [ -z "$SRC_DUR" ]; then SRC_DUR=1; fi
SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" | bc -l)
if [ -z "$SRC_FPS" ]; then SRC_FPS=30; fi

# إعدادات
SEG_TIME=10
GOP_SIZE=$(calc "int($SRC_FPS * $SEG_TIME)")
PRESET="veryslow"
TUNE="animation"

# كتابة رأس التقرير
{
    echo "METRICS REPORT FOR: $FILENAME"
    echo "Duration: $SRC_DUR seconds"
    echo "----------------------------------------------------------------------"
    printf "| %-8s | %-10s | %-10s | %-7s | %-6s | %-6s |\n" "Quality" "Size" "Bitrate" "Reduct" "BPP" "Segs"
    echo "----------------------------------------------------------------------"
} > "$REPORT_FILE"

# مصفوفة الجودات
declare -a QUALITIES
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT_FILE")
if [ "$SRC_H" -ge 1080 ]; then QUALITIES+=("1080p 1920 2500k 3000k 6000k"); fi
if [ "$SRC_H" -ge 720 ]; then QUALITIES+=("720p 1280 1400k 1800k 3600k"); fi
QUALITIES+=("480p 854 600k 900k 1800k")

# تنظيف الماستر
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"

echo ">> [2/3] Transcoding..."

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH BITRATE MAXRATE BUFSIZE <<< "$quality"
    
    echo "   -> Layer: $NAME"
    
    # 1. تنفيذ FFmpeg
    ffmpeg -y -hide_banner -loglevel error -nostdin \
        -i "$INPUT_FILE" \
        -vf "scale=w=${WIDTH}:h=-2" \
        -c:v libx264 -profile:v high -preset "$PRESET" -tune "$TUNE" -crf 23 \
        -b:v "$BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEG_TIME" \
        -hls_playlist_type vod \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8" < /dev/null

    # انتظار انتهاء الكتابة
    sleep 1
    
    # التحقق من الملفات
    FIRST_SEG=$(ls "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | head -n 1)
    
    if [ -z "$FIRST_SEG" ]; then
        echo "      [ERROR] Segment not found!"
        continue
    else
        echo "      [OK] Output generated."
    fi
    
    # حساب الحجم الكلي
    TOTAL_SIZE=$(stat -c%s "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | awk '{s+=$1} END {print s+0}')
    if [ -z "$TOTAL_SIZE" ]; then TOTAL_SIZE=0; fi

    # ==========================================
    # MATH FIX: Calculate Bitrate Manually
    # ==========================================
    
    # Bitrate = (Size * 8) / Duration
    # نستخدم مدة الفيديو الأصلية للحساب
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        CALC_BITRATE=$(awk "BEGIN { print int(($TOTAL_SIZE * 8) / $SRC_DUR) }" 2>/dev/null)
    else
        CALC_BITRATE=0
    fi

    # الحسابات
    REDUCTION=$(calc "100 - ($TOTAL_SIZE * 100 / $SRC_SIZE)")
    
    # BPP Calculation (Using Calculated Bitrate)
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$FIRST_SEG")
    if [ -z "$ACTUAL_H" ]; then ACTUAL_H=1; fi
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$CALC_BITRATE / ($PIXELS * $SRC_FPS)")
    
    SEG_COUNT=$(ls "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | wc -l)

    # التنسيق
    if [ "$TOTAL_SIZE" -eq "0" ]; then F_SIZE="0B"; else F_SIZE=$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE); fi
    if [ "$CALC_BITRATE" -eq "0" ]; then F_BITRATE="0bps"; else F_BITRATE=$(numfmt --to=iec-i --suffix=bps $CALC_BITRATE); fi

    # الكتابة
    printf "| %-8s | %-10s | %-10s | %-7.2f | %-1.4f | %-6d |\n" \
        "$NAME" "$F_SIZE" "$F_BITRATE" "$REDUCTION" "$BPP" "$SEG_COUNT" >> "$REPORT_FILE"

    # الماستر (يستخدم الـ Maxrate للأمان في ملف البلاي ليست)
    BW=${MAXRATE%k}000
    echo "#EXT-X-STREAM-INF:BANDWIDTH=$BW,RESOLUTION=${WIDTH}x${ACTUAL_H}" >> "$OUTPUT_DIR/master.m3u8"
    echo "${NAME}.m3u8" >> "$OUTPUT_DIR/master.m3u8"

done

echo ">> [3/3] Done. Check: $REPORT_FILE"