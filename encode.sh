#!/bin/bash

# ==============================================================================
#  MASTER PRODUCTION ENCODER: Robust + Detailed Analytics
# ==============================================================================

# 1. التحقق من المدخلات
if [ -z "$1" ]; then
    echo "Usage: ./encode_master.sh <input_video.mp4>"
    exit 1
fi

# 2. إعداد المسارات (Absolute Paths)
# استخدام LC_NUMERIC لضمان استخدام النقطة في الكسور وليس الفاصلة
export LC_NUMERIC="C"

INPUT_FILE=$(realpath "$1")
FILENAME=$(basename -- "$INPUT_FILE")
BASENAME="${FILENAME%.*}"

CURRENT_DIR=$(pwd)
OUTPUT_FOLDER_NAME="results_${BASENAME}"
OUTPUT_DIR="${CURRENT_DIR}/${OUTPUT_FOLDER_NAME}"
REPORT_FILE="$OUTPUT_DIR/REPORT_MASTER.txt"

# التأكد من الأدوات
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required."; exit 1; }

echo "--------------------------------------------------------"
echo ">> [INIT] Input:  $FILENAME"
echo ">> [INIT] Output: $OUTPUT_DIR"
echo "--------------------------------------------------------"

mkdir -p "$OUTPUT_DIR"

# دالة حساب آمنة
calc() { awk "BEGIN { print $* }" 2>/dev/null || echo "0"; }

# --- 3. تحليل المصدر (Source Anatomy) ---
echo ">> [1/3] Analyzing Source DNA..."

SRC_SIZE=$(stat --printf="%s" "$INPUT_FILE")
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")
if [ -z "$SRC_DUR" ]; then SRC_DUR=1; fi

# استخراج الفريم ريت بدقة لحساب GOP
SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" | bc -l)
if [ -z "$SRC_FPS" ]; then SRC_FPS=30; fi

SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$INPUT_FILE")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT_FILE")

# حساب البت ريت الأصلي يدوياً للدقة
SRC_BITRATE=$(calc "int($SRC_SIZE * 8 / $SRC_DUR)")

# --- 4. إعدادات الترميز (The Agreed Strategy) ---
SEG_TIME=10
# GOP Size = FPS * 10 seconds (Strictly Aligned)
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
    echo "  • GOP Target: $GOP_SIZE frames (Strictly every 10s)"
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

# تنظيف الماستر
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"

echo ">> [2/3] Transcoding..."

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH TARGET_BITRATE MAXRATE BUFSIZE <<< "$quality"
    
    echo "   -> Processing: $NAME ($WIDTH width)..."
    
    # 1. تنفيذ FFmpeg (Robust Mode)
    # -sc_threshold 0: يمنع إضافة Keyframes عشوائية
    # -nostdin + < /dev/null: يمنع تجمد WSL
    ffmpeg -y -hide_banner -loglevel warning -nostdin \
        -i "$INPUT_FILE" \
        -vf "scale=w=${WIDTH}:h=-2" \
        -c:v libx264 -profile:v high -preset "$PRESET" -tune "$TUNE" -crf 28 \
        -b:v "$TARGET_BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -flags +cgop \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEG_TIME" \
        -hls_playlist_type vod \
        -hls_segment_type mpegts \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8" < /dev/null

    ffmpeg -y -hide_banner -loglevel warning -stats \
            -i \"$INPUT\" \
            -vf scale=w=${SCALE_WIDTH}:h=-2:flags=lanczos \
            -c:v libx264 -preset $preset -tune animation \
            -crf 28 -maxrate 1500k -bufsize 3000k \
            -g 240 -keyint_min 24 -sc_threshold 40 \
            -c:a aac -b:a 128k \
            -hls_time 10 -hls_playlist_type vod \
            -hls_segment_filename \"$output/video_%03d.ts\" \
            \"$output/video.m3u8\"


    # انتظار بسيط لنظام الملفات
    sleep 1
    
    # --- 5. التحليلات (The Analytics Engine) ---

    # التحقق من وجود الملفات
    FILE_COUNT=$(ls "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | wc -l)
    
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "      [ERROR] No Output Files for $NAME!"
        continue
    fi
    
    # A. الحجم الكلي
    TOTAL_SIZE=$(stat -c%s "$OUTPUT_DIR"/${NAME}_*.ts 2>/dev/null | awk '{s+=$1} END {print s+0}')
    
    # B. البت ريت الفعلي (Manual Calculation)
    if [ "$TOTAL_SIZE" -gt 0 ]; then
        ACTUAL_BITRATE=$(calc "int(($TOTAL_SIZE * 8) / $SRC_DUR)")
    else
        ACTUAL_BITRATE=0
    fi

    # C. نسبة التخفيض (Reduction)
    REDUCTION_PCT=$(calc "100 - ($TOTAL_SIZE * 100 / $SRC_SIZE)")

    # D. BPP (Bits Per Pixel)
    # نحتاج الارتفاع الفعلي للملف الناتج
    FIRST_SEG=$(ls "$OUTPUT_DIR"/${NAME}_*.ts | head -n 1)
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$FIRST_SEG")
    if [ -z "$ACTUAL_H" ]; then ACTUAL_H=1; fi
    
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$ACTUAL_BITRATE / ($PIXELS * $SRC_FPS)")

    # E. Overhead Calculation (حساب الهدر)
    # الهدر = الحجم الكلي - (حجم الفيديو الصافي المتوقع + حجم الصوت)
    # سنفترض أن الفيديو الصافي هو البت ريت المحسوب، لذا سنحسب overhead الـ Container مقارنة بالـ Stream الخام
    # الطريقة الأدق: استخراج حجم الـ Stream فقط باستخدام ffprobe (لكنها بطيئة)، لذا سنستخدم المعادلة التقريبية:
    # Overhead = TotalBytes - ((VideoBitrate + AudioBitrate) * Duration / 8)
    # لكن بما أننا حسبنا ActualBitrate من الحجم الكلي، فالمعادلة ستكون صفرية.
    # لذلك سنستخدم معادلة تقريبية لهدر MPEG-TS المعروف (حوالي 10% إلى 15% زيادة عن MP4)
    # أو نقارن الحجم الفعلي بالحجم النظري (Target Bitrate).
    # الأفضل: سنقارنه مع حجم MP4 "نظري" بنفس البت ريت.
    
    # سنقوم بحساب نسبة الزيادة عن البت ريت المستهدف (إذا تجاوزناه) أو نتركه فارغاً إذا كان أقل.
    # سأستعيد معادلة Overhead الحقيقية (الفرق بين حجم الملف وحجم البيانات المفيدة بداخله)
    # نحتاج لقراءة حجم الـ Packet Data.. وهذا معقد.
    # سأستخدم معادلة بسيطة: (Total Size) vs (Duration * Stream Bitrate reported by ffprobe)
    
    STREAM_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$FIRST_SEG")
    if [ -z "$STREAM_BITRATE" ] || [ "$STREAM_BITRATE" == "N/A" ]; then 
        # Fallback if ffprobe fails on TS
        STREAM_BITRATE=$ACTUAL_BITRATE 
        OVERHEAD_PCT="0.00%"
    else
        # إذا نجح ffprobe في قراءة بت ريت الفيديو فقط (بدون الـ header)
        STREAM_BITRATE=${STREAM_BITRATE//[^0-9]/}
        # حجم البيانات الصافية (فيديو + صوت 128k)
        RAW_SIZE_BITS=$(calc "($STREAM_BITRATE + 128000) * $SRC_DUR")
        RAW_SIZE_BYTES=$(calc "$RAW_SIZE_BITS / 8")
        OVERHEAD_BYTES=$(calc "$TOTAL_SIZE - $RAW_SIZE_BYTES")
        OVERHEAD_PCT=$(calc "($OVERHEAD_BYTES * 100) / $TOTAL_SIZE")
        OVERHEAD_PCT="${OVERHEAD_PCT}%"
    fi

    # تنسيق الأرقام
    F_SIZE=$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE)
    F_BITRATE=$(numfmt --to=iec-i --suffix=bps $ACTUAL_BITRATE)
    F_REDUCT=$(printf "%.2f%%" "$REDUCTION_PCT")
    F_BPP=$(printf "%.4f" "$BPP")

    # الكتابة في التقرير
    printf "| %-8s | %-10s | %-10s | %-7s | %-6s | %-8s | %-4d |\n" \
        "$NAME" "$F_SIZE" "$F_BITRATE" "$F_REDUCT" "$F_BPP" "$OVERHEAD_PCT" "$FILE_COUNT" >> "$REPORT_FILE"

    # إضافة للماستر
    BW=${MAXRATE%k}000
    echo "#EXT-X-STREAM-INF:BANDWIDTH=$BW,RESOLUTION=${WIDTH}x${ACTUAL_H}" >> "$OUTPUT_DIR/master.m3u8"
    echo "${NAME}.m3u8" >> "$OUTPUT_DIR/master.m3u8"

done

echo ">> [3/3] Done. Check Report: $REPORT_FILE"