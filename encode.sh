#!/bin/bash

# ==============================================================================
#  ROBUST HLS LAB: Transcoding & Analysis (Error-Safe Version)
# ==============================================================================

if [ -z "$1" ]; then
    echo "Usage: ./encode.sh <input_video.mp4>"
    exit 1
fi

INPUT="$1"
FILENAME=$(basename -- "$INPUT")
BASENAME="${FILENAME%.*}"
OUTPUT_DIR="./lab_results_${BASENAME}"
REPORT_FILE="$OUTPUT_DIR/REPORT_STRUCTURAL.txt"

# التأكد من وجود أدوات الحساب
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required. Install with 'sudo apt install bc'"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# دالة للتقريب العشري (آمنة)
calc() { 
    res=$(awk "BEGIN { print $* }" 2>/dev/null)
    if [ -z "$res" ]; then echo "0"; else echo "$res"; fi
}

# --- 1. فحص المصدر (Source Analysis) ---
echo ">> [1/3] Analyzing Source DNA..."

SRC_SIZE=$(stat --printf="%s" "$INPUT")
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT")
SRC_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT")

# إصلاح القيم الفارغة للمصدر
if [ -z "$SRC_BITRATE" ] || [ "$SRC_BITRATE" == "N/A" ]; then
    SRC_BITRATE=$(calc "$SRC_SIZE * 8 / $SRC_DUR")
fi
if [ -z "$SRC_FPS" ]; then SRC_FPS=30; fi # Default fallback

SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$INPUT")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT")
SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)

# --- إعدادات المختبر ---
SEG_TIME=10
GOP_SIZE=$(calc "int($SRC_FPS * $SEG_TIME)")
PRESET="veryslow"
TUNE="animation"

# إنشاء ترويسة التقرير
{
    echo "=================================================================================="
    echo "                     HLS STRUCTURAL REPORT: $FILENAME"
    echo "=================================================================================="
    echo "SOURCE ANATOMY:"
    printf "  • %-15s : %dx%d\n" "Resolution" "$SRC_W" "$SRC_H"
    printf "  • %-15s : %.2f fps (GOP Target: %d frames)\n" "Frame Rate" "$SRC_FPS" "$GOP_SIZE"
    printf "  • %-15s : %.2f seconds\n" "Duration" "$SRC_DUR"
    printf "  • %-15s : %s\n" "File Size" "$(numfmt --to=iec-i --suffix=B $SRC_SIZE)"
    echo "=================================================================================="
    echo "DETAILED EFFICIENCY MATRIX:"
    printf "| %-8s | %-10s | %-10s | %-9s | %-7s | %-10s | %-6s |\n" \
           "Quality" "T.Size" "V.Bitrate" "Reduct." "BPP" "Overhead" "Segs"
    printf "|%s|%s|%s|%s|%s|%s|%s|\n" \
           "----------" "----------" "----------" "---------" "-------" "----------" "------"
} > "$REPORT_FILE"

# --- 2. إعداد مصفوفة الجودات ---
declare -a QUALITIES
if [ "$SRC_H" -ge 1080 ]; then
    QUALITIES+=("1080p 1920 2500k 3000k 6000k")
fi
if [ "$SRC_H" -ge 720 ]; then
    QUALITIES+=("720p 1280 1400k 1800k 3600k")
fi
QUALITIES+=("480p 854 600k 900k 1800k")

# تجهيز ملف الماستر
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"

echo ">> [2/3] Starting Transcoding Engines..."
START_GLOBAL=$(date +%s)

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH BITRATE MAXRATE BUFSIZE <<< "$quality"
    
    echo "   -> Processing Layer: $NAME ($WIDTH width)..."
    
    # الترميز (مع -nostdin وكشف الأخطاء)
    ffmpeg -y -hide_banner -loglevel warning -nostdin \
        -i "$INPUT" \
        -vf "scale=w=${WIDTH}:h=-2" \
        -c:v libx264 -profile:v high -preset "$PRESET" -tune "$TUNE" -crf 23 \
        -b:v "$BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEG_TIME" \
        -hls_playlist_type vod \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8" || { echo "!!!! ERROR: Transcoding failed for $NAME. Check logs above."; exit 1; }

    # التحليل الهيكلي (مع حماية من القيم الفارغة)
    TOTAL_SIZE=$(find "$OUTPUT_DIR" -name "${NAME}_*.ts" -exec stat --printf="%s+" {} + | sed 's/+$//' | bc)
    if [ -z "$TOTAL_SIZE" ]; then TOTAL_SIZE=0; fi

    # حماية: إذا لم ينتج ملفات، لا نكمل الحسابات
    if [ "$TOTAL_SIZE" -eq 0 ]; then
        echo "Warning: No output files found for $NAME"
        continue
    fi
    
    SAMPLE_TS=$(ls "$OUTPUT_DIR"/${NAME}_001.ts 2>/dev/null)
    VIDEO_ONLY_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$SAMPLE_TS")
    if [ -z "$VIDEO_ONLY_BITRATE" ] || [ "$VIDEO_ONLY_BITRATE" == "N/A" ]; then VIDEO_ONLY_BITRATE=$BITRATE; fi
    
    REDUCTION_PCT=$(calc "100 - ($TOTAL_SIZE * 100 / $SRC_SIZE)")

    # حساب الهدر (Overhead)
    EXPECTED_SIZE_BITS=$(calc "$VIDEO_ONLY_BITRATE * $SRC_DUR + 128000 * $SRC_DUR") 
    EXPECTED_SIZE_BYTES=$(calc "$EXPECTED_SIZE_BITS / 8")
    OVERHEAD_BYTES=$(calc "$TOTAL_SIZE - $EXPECTED_SIZE_BYTES")
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        OVERHEAD_PCT=$(calc "($OVERHEAD_BYTES * 100) / $TOTAL_SIZE")
    else
        OVERHEAD_PCT="0"
    fi
    
    # حساب BPP
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$SAMPLE_TS")
    if [ -z "$ACTUAL_H" ]; then ACTUAL_H=1; fi
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$VIDEO_ONLY_BITRATE / ($PIXELS * $SRC_FPS)")

    SEG_COUNT=$(ls "$OUTPUT_DIR"/${NAME}_*.ts | wc -l)

    # تنسيق الأرقام
    FMT_SIZE=$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE 2>/dev/null || echo "$TOTAL_SIZE")
    FMT_BITRATE=$(numfmt --to=iec-i --suffix=bps ${VIDEO_ONLY_BITRATE%.*} 2>/dev/null || echo "$VIDEO_ONLY_BITRATE")

    # الكتابة في التقرير
    printf "| %-8s | %-10s | %-10s | %-8.2f%% | %-1.4f | %-8.2f%% | %-6d |\n" \
        "$NAME" \
        "$FMT_SIZE" \
        "$FMT_BITRATE" \
        "$REDUCTION_PCT" \
        "$BPP" \
        "$OVERHEAD_PCT" \
        "$SEG_COUNT" >> "$REPORT_FILE"

    # إضافة للماستر
    BANDWIDTH_BITS=$(calc "$MAXRATE * 1000")
    BANDWIDTH_BITS=${BANDWIDTH_BITS%.*}
    echo "#EXT-X-STREAM-INF:BANDWIDTH=$BANDWIDTH_BITS,RESOLUTION=${WIDTH}x${ACTUAL_H}" >> "$OUTPUT_DIR/master.m3u8"
    echo "${NAME}.m3u8" >> "$OUTPUT_DIR/master.m3u8"

done

END_GLOBAL=$(date +%s)
DURATION=$((END_GLOBAL - START_GLOBAL))

# --- 3. الخاتمة ---
{
    echo "----------------------------------------------------------------------------------"
    echo "PROCESSED IN: $DURATION seconds."
} >> "$REPORT_FILE"

echo ">> [3/3] Done. Report ready at: $REPORT_FILE"