#!/bin/bash

# ==============================================================================
#  MASTER PRODUCTION ENCODER: Fast Start + Robust Analytics + Safety
# ==============================================================================

# 1. التحقق من المدخلات
if [ -z "$1" ]; then
    echo "Usage: ./encode_master.sh <input_video.mp4>"
    exit 1
fi

# 2. إعداد المسارات
export LC_NUMERIC="C"

INPUT_FILE=$(realpath "$1")
FILENAME=$(basename -- "$INPUT_FILE")
BASENAME="${FILENAME%.*}"

# استخدام المجلد الحالي
OUTPUT_DIR=$(pwd)
REPORT_FILE="$OUTPUT_DIR/REPORT_MASTER.txt"

# التأكد من الأدوات
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required."; exit 1; }

echo "--------------------------------------------------------"
echo ">> [INIT] Input:  $FILENAME"
echo ">> [INIT] Output: $OUTPUT_DIR"
echo "--------------------------------------------------------"

# دالة حساب آمنة
calc() { awk "BEGIN { print $* }" 2>/dev/null || echo "0"; }

# --- 3. تحليل المصدر ---
echo ">> [1/3] Analyzing Source DNA..."

SRC_SIZE=$(stat --printf="%s" "$INPUT_FILE")
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")
if [ -z "$SRC_DUR" ]; then SRC_DUR=1; fi

SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" | bc -l)
if [ -z "$SRC_FPS" ]; then SRC_FPS=30; fi

SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$INPUT_FILE")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT_FILE")

SRC_BITRATE=$(calc "int($SRC_SIZE * 8 / $SRC_DUR)")

# --- 4. إعدادات الترميز (Fast Start Optimized) ---
SEG_TIME=4
GOP_SIZE=$(calc "int($SRC_FPS * $SEG_TIME)")
PRESET="veryslow"
TUNE="animation"

# كتابة رأس التقرير
{
    echo "======================================================================"
    echo "                  MASTER ENCODING REPORT"
    echo "======================================================================"
    echo "SOURCE METRICS:"
    echo "  • File:       $FILENAME"
    echo "  • Duration:   $SRC_DUR sec"
    echo "  • Resolution: ${SRC_W}x${SRC_H}"
    echo "  • FPS:        $SRC_FPS"
    echo "  • Bitrate:    $(numfmt --to=iec-i --suffix=bps $SRC_BITRATE)"
    echo "======================================================================"
    echo "EFFICIENCY MATRIX:"
    printf "| %-8s | %-10s | %-10s | %-7s | %-6s | %-8s | %-4s |\n" \
           "Quality" "Size" "Bitrate" "Reduct." "BPP" "Overhead" "Segs"
    printf "|%s|%s|%s|%s|%s|%s|%s|\n" \
           "----------" "----------" "----------" "-------" "------" "--------" "----"
} > "$REPORT_FILE"

# مصفوفة الجودات
declare -a QUALITIES
if [ "$SRC_H" -ge 1080 ]; then QUALITIES+=("1080p 1920 2500k 3000k 6000k"); fi
if [ "$SRC_H" -ge 720 ]; then QUALITIES+=("720p 1280 1400k 1800k 3600k"); fi
QUALITIES+=("480p 854 600k 900k 1800k");

# تنظيف الماستر وإنشاء الهيدر
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"

echo ">> [2/3] Transcoding (Fast Start Mode)..."

# [TIMER START]
START_TIME=$(date +%s)

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH TARGET_BITRATE MAXRATE BUFSIZE <<< "$quality"
    
    echo "   -> Processing: $NAME ($WIDTH width)..."
    
    # تنفيذ FFmpeg
    ffmpeg -y -hide_banner -loglevel warning -nostdin \
        -i "$INPUT_FILE" \
        -vf "scale=w=${WIDTH}:h=-2" \
        -c:v libx264 -profile:v high -preset "$PRESET" -tune "$TUNE" -crf 23 \
        -b:v "$TARGET_BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -force_key_frames "expr:gte(t,n_forced*$SEG_TIME)" \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEG_TIME" \
        -hls_playlist_type vod \
        -hls_flags independent_segments \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8" < /dev/null

    # --- 5. التحليلات ---
    FILE_COUNT=$(ls "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | wc -l)
    
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "      [ERROR] No Output Files for $NAME!"
        continue
    fi
    
    TOTAL_SIZE=$(stat -c%s "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | awk '{s+=$1} END {print s+0}')
    
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        ACTUAL_BITRATE=$(calc "int(($TOTAL_SIZE * 8) / $SRC_DUR)")
    else
        ACTUAL_BITRATE=0
    fi

    REDUCTION_PCT=$(calc "100 - ($TOTAL_SIZE * 100 / $SRC_SIZE)")

    FIRST_SEG=$(ls "$OUTPUT_DIR"/${NAME}_*.ts | head -n 1)
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$FIRST_SEG")
    if [ -z "$ACTUAL_H" ]; then ACTUAL_H=1; fi
    
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$ACTUAL_BITRATE / ($PIXELS * $SRC_FPS)")

    STREAM_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$FIRST_SEG")
    if [ -z "$STREAM_BITRATE" ] || [ "$STREAM_BITRATE" == "N/A" ]; then 
        OVERHEAD_PCT="0.00%"
    else
        STREAM_BITRATE=${STREAM_BITRATE//[^0-9]/}
        RAW_SIZE_BITS=$(calc "($STREAM_BITRATE + 128000) * $SRC_DUR")
        RAW_SIZE_BYTES=$(calc "$RAW_SIZE_BITS / 8")
        OVERHEAD_BYTES=$(calc "$TOTAL_SIZE - $RAW_SIZE_BYTES")
        OVERHEAD_PCT=$(calc "($OVERHEAD_BYTES * 100) / $TOTAL_SIZE")
        OVERHEAD_PCT="${OVERHEAD_PCT}%"
    fi

    F_SIZE=$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE)
    F_BITRATE=$(numfmt --to=iec-i --suffix=bps $ACTUAL_BITRATE)
    F_REDUCT=$(printf "%.2f%%" "$REDUCTION_PCT")
    F_BPP=$(printf "%.4f" "$BPP")

    printf "| %-8s | %-10s | %-10s | %-7s | %-6s | %-8s | %-4d |\n" \
        "$NAME" "$F_SIZE" "$F_BITRATE" "$F_REDUCT" "$F_BPP" "$OVERHEAD_PCT" "$FILE_COUNT" >> "$REPORT_FILE"

    # --- إنشاء الماستر الآمن ---
    CLEAN_BW=$(echo "${MAXRATE}" | tr -d 'k')000
    printf "#EXT-X-STREAM-INF:BANDWIDTH=%s,RESOLUTION=%sx%s\n%s.m3u8\n" \
        "$CLEAN_BW" "$WIDTH" "$ACTUAL_H" "$NAME" >> "$OUTPUT_DIR/master.m3u8"

done

# [TIMER END] حساب الوقت وإضافته للتقرير فقط
END_TIME=$(date +%s)
ELAPSED_TIME=$(($END_TIME - $START_TIME))
FORMATTED_TIME=$(printf '%02dh:%02dm:%02ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

if [ "$ELAPSED_TIME" -gt 0 ]; then
    SPEED_FACTOR=$(calc "$SRC_DUR / $ELAPSED_TIME")
else
    SPEED_FACTOR="N/A"
fi

# الكتابة داخل الملف فقط
{
    echo "======================================================================"
    echo "PERFORMANCE METRICS:"
    echo "  • Total Time:   $ELAPSED_TIME seconds ($FORMATTED_TIME)"
    echo "  • Speed Factor: ${SPEED_FACTOR}x (Higher is faster)"
    echo "======================================================================"
} >> "$REPORT_FILE"

# ------------------------------------------------------------------
# SAFETY FILTER
# ------------------------------------------------------------------
echo ">> [INFO] Sanitizing Master Playlist..."

sed -i '/^$/d' "$OUTPUT_DIR/master.m3u8"
sed -i '/^[0-9]\+$/d' "$OUTPUT_DIR/master.m3u8"

echo ">> [3/3] Done. Check Report: $REPORT_FILE"