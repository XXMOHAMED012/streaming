#!/bin/bash

# ==============================================================================
#  ADVANCED HLS LAB: Transcoding, Quality Analysis & Deep Reporting
# ==============================================================================

if [ -z "$1" ]; then
    echo "Usage: ./deep_encode_lab.sh <input_video.mp4>"
    exit 1
fi

INPUT="$1"
FILENAME=$(basename -- "$INPUT")
BASENAME="${FILENAME%.*}"
OUTPUT_DIR="./lab_results_${BASENAME}"
REPORT_FILE="$OUTPUT_DIR/DEEP_REPORT.txt"

# التأكد من وجود الأدوات
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required. Install with 'sudo apt install bc'"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# دالة للتقريب العشري
calc() { awk "BEGIN { print $*}"; }

# --- 1. فحص المصدر بالأشعة السينية (Deep Source Analysis) ---
echo ">> [1/4] Analyzing Source DNA..."

SRC_SIZE=$(stat --printf="%s" "$INPUT")
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT")
SRC_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT")

# إذا لم نجد البت ريت في الميتاداتا، نحسبه
if [ -z "$SRC_BITRATE" ] || [ "$SRC_BITRATE" == "N/A" ]; then
    SRC_BITRATE=$(calc "$SRC_SIZE * 8 / $SRC_DUR")
fi

SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$INPUT")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT")
SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
SRC_AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$INPUT")

# --- إعدادات المختبر ---
SEG_TIME=10
# حساب الـ GOP بدقة متناهية
GOP_SIZE=$(calc "int($SRC_FPS * $SEG_TIME)")
PRESET="veryslow"
TUNE="animation"

# إنشاء ترويسة التقرير
{
    echo "=================================================================================="
    echo "                     HLS DEEP LAB REPORT: $FILENAME"
    echo "=================================================================================="
    echo "SOURCE ANATOMY:"
    printf "  • %-15s : %dx%d\n" "Resolution" $SRC_W $SRC_H
    printf "  • %-15s : %.2f fps (GOP Target: %d frames)\n" "Frame Rate" $SRC_FPS $GOP_SIZE
    printf "  • %-15s : %.2f seconds\n" "Duration" $SRC_DUR
    printf "  • %-15s : %s\n" "File Size" "$(numfmt --to=iec-i --suffix=B $SRC_SIZE)"
    printf "  • %-15s : %s\n" "Total Bitrate" "$(numfmt --to=iec-i --suffix=bps $SRC_BITRATE)"
    printf "  • %-15s : %s\n" "Audio Codec" "$SRC_AUDIO_CODEC"
    echo "=================================================================================="
    echo "TRANSCODING STRATEGY:"
    echo "  • Codec: H.264 (High Profile) | Audio: AAC-LC"
    echo "  • Preset: $PRESET | Tune: $TUNE"
    echo "  • Segmentation: Strictly ${SEG_TIME}s (Aligned GOP)"
    echo "=================================================================================="
    echo ""
    echo "DETAILED QUALITY MATRIX:"
    # رأس الجدول
    printf "| %-8s | %-10s | %-10s | %-9s | %-6s | %-7s | %-10s | %-6s |\n" \
           "Quality" "T.Size" "V.Bitrate" "Reduct." "SSIM*" "BPP" "Overhead" "Segs"
    printf "|%s|%s|%s|%s|%s|%s|%s|%s|\n" \
           "----------" "----------" "----------" "---------" "------" "-------" "----------" "------"
} > "$REPORT_FILE"

# --- 2. إعداد مصفوفة الجودات ---
declare -a QUALITIES
# Format: Name Width Bitrate Maxrate Bufsize
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

echo ">> [2/4] Starting Transcoding Engines..."

# --- 3. حلقة المعالجة والتحليل ---
START_GLOBAL=$(date +%s)

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH BITRATE MAXRATE BUFSIZE <<< "$quality"
    
    echo "   -> Processing Layer: $NAME ($WIDTH width)..."
    
    # 3.1: الترميز (Encoding)
    ffmpeg -y -hide_banner -loglevel error \
        -i "$INPUT" \
        -vf "scale=w=${WIDTH}:h=-2" \
        -c:v libx264 -profile:v high -preset "$PRESET" -tune "$TUNE" -crf 23 \
        -b:v "$BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEG_TIME" \
        -hls_playlist_type vod \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8"

    # 3.2: التحليل العميق (Post-Mortem Analysis)
    
    # أ) الحجم الكلي
    TOTAL_SIZE=$(find "$OUTPUT_DIR" -name "${NAME}_*.ts" -exec stat --printf="%s+" {} + | sed 's/+$//' | bc)
    
    # ب) حساب البت ريت الفعلي للفيديو فقط (بدون الصوت والكونتينر)
    # نستخدم ffprobe على أول 3 ملفات لأخذ متوسط دقيق للـ Stream الفعلي
    SAMPLE_TS=$(ls "$OUTPUT_DIR"/${NAME}_001.ts)
    VIDEO_ONLY_BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$SAMPLE_TS")
    if [ -z "$VIDEO_ONLY_BITRATE" ] || [ "$VIDEO_ONLY_BITRATE" == "N/A" ]; then VIDEO_ONLY_BITRATE=$BITRATE; fi # Fallback
    
    # ج) حساب نسبة التخفيض
    REDUCTION_PCT=$(calc "100 - ($TOTAL_SIZE * 100 / $SRC_SIZE)")

    # د) حساب الـ Overhead (الفرق بين حجم الملف وحجم البيانات الخام)
    # الحجم المتوقع = (Bitrate * Duration) / 8
    # الفرق هو الـ Container Overhead
    # هذه معادلة تقريبية ذكية
    EXPECTED_SIZE_BITS=$(calc "$VIDEO_ONLY_BITRATE * $SRC_DUR + 128000 * $SRC_DUR") # Video + Audio bits
    EXPECTED_SIZE_BYTES=$(calc "$EXPECTED_SIZE_BITS / 8")
    OVERHEAD_BYTES=$(calc "$TOTAL_SIZE - $EXPECTED_SIZE_BYTES")
    OVERHEAD_PCT=$(calc "($OVERHEAD_BYTES * 100) / $TOTAL_SIZE")
    
    # هـ) حساب BPP (Bits Per Pixel)
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$SAMPLE_TS")
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$VIDEO_ONLY_BITRATE / ($PIXELS * $SRC_FPS)")

    # و) حساب SSIM (جودة الصورة) - سنأخذ عينة لأول 30 ثانية لتوفير الوقت
    # نقوم بمقارنة الستريم المنتج مع الملف الأصلي (مع عمل Scale للأصل ليطابق المنتج)
    # ملاحظة: هذه العملية تستهلك CPU
    echo "      ... Calculating SSIM score (Quality Check) ..."
    SSIM_LOG=$(ffmpeg -hide_banner -i "$OUTPUT_DIR/${NAME}.m3u8" -i "$INPUT" \
        -filter_complex "[0:v]setpts=PTS-STARTPTS[dist];[1:v]scale=${WIDTH}:${ACTUAL_H}:force_original_aspect_ratio=decrease,setpts=PTS-STARTPTS[ref];[dist][ref]ssim" \
        -t 30 -f null - 2>&1 | grep "SSIM All")
    
    # استخراج الرقم (Y:0.9xxx)
    SSIM_VAL=$(echo $SSIM_LOG | grep -oP 'All:\K[0-9.]+')
    if [ -z "$SSIM_VAL" ]; then SSIM_VAL="N/A"; fi

    # ز) عدد القطع
    SEG_COUNT=$(ls "$OUTPUT_DIR"/${NAME}_*.ts | wc -l)

    # --- الكتابة في التقرير ---
    printf "| %-8s | %-10s | %-10s | %-8.2f%% | %-6s | %-1.4f | %-8.2f%% | %-6d |\n" \
        "$NAME" \
        "$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE)" \
        "$(numfmt --to=iec-i --suffix=bps $VIDEO_ONLY_BITRATE)" \
        "$REDUCTION_PCT" \
        "$SSIM_VAL" \
        "$BPP" \
        "$OVERHEAD_PCT" \
        "$SEG_COUNT" >> "$REPORT_FILE"

    # إضافة للماستر
    BANDWIDTH_BITS=$(calc "$MAXRATE * 1000") # نستخدم Maxrate في الماستر للأمان
    # تصحيح الـ bandwidth ليكون integer
    BANDWIDTH_BITS=${BANDWIDTH_BITS%.*}
    echo "#EXT-X-STREAM-INF:BANDWIDTH=$BANDWIDTH_BITS,RESOLUTION=${WIDTH}x${ACTUAL_H}" >> "$OUTPUT_DIR/master.m3u8"
    echo "${NAME}.m3u8" >> "$OUTPUT_DIR/master.m3u8"

done

END_GLOBAL=$(date +%s)
DURATION=$((END_GLOBAL - START_GLOBAL))

# --- 4. الخاتمة ---
{
    echo "----------------------------------------------------------------------------------"
    echo "* SSIM (Structural Similarity): 1.0 is identical to source. >0.95 is excellent."
    echo "* Overhead: Percentage of file size used by TS container (wasted space)."
    echo "* BPP: Bits Per Pixel. For animation/screencasts, 0.05-0.1 is usually enough."
    echo "=================================================================================="
    echo "LAB COMPLETED IN: $DURATION seconds."
    echo "SPEED FACTOR: $(calc "$SRC_DUR / $DURATION")x real-time"
} >> "$REPORT_FILE"

echo ">> [4/4] Mission Complete."
echo ">> Deep report generated at: $REPORT_FILE"