#!/bin/bash

# ==============================================================================
#  MASTER ENCODER V3: Smart Resolutions + Detailed Forensics + Folder Structure
# ==============================================================================

# 1. التحقق من المدخلات
if [ -z "$1" ]; then
    echo "Usage: ./encode_master.sh <input_video.mp4>"
    exit 1
fi

# إعداد المسارات
export LC_NUMERIC="C"
INPUT_FILE=$(realpath "$1")
FILENAME=$(basename -- "$INPUT_FILE")
OUTPUT_DIR=$(pwd)
REPORT_FILE="$OUTPUT_DIR/REPORT_MASTER.txt"

# التحقق من الأدوات
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo >&2 "Error: 'ffprobe' is required."; exit 1; }

# دالة حسابية
calc() { awk "BEGIN { print $* }" 2>/dev/null || echo "0"; }

# ------------------------------------------------------------------------------
# 2. تحليل المصدر (Source Analysis)
# ------------------------------------------------------------------------------
echo ">> [1/4] Analyzing Source DNA..."

SRC_SIZE_BYTES=$(stat --printf="%s" "$INPUT_FILE")
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")
SRC_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" | bc -l)
SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$INPUT_FILE")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT_FILE")
SRC_BITRATE_BPS=$(calc "int($SRC_SIZE_BYTES * 8 / $SRC_DUR)")
SRC_BITRATE_KBPS=$(calc "int($SRC_BITRATE_BPS / 1000)")
SRC_SIZE_MB=$(calc "$SRC_SIZE_BYTES / 1024 / 1024")

# كتابة رأس التقرير (بيانات المقطع الأصلي)
{
    echo "======================================================================"
    echo "                     MASTER ENCODING REPORT"
    echo "======================================================================"
    echo "ORIGINAL FILE METRICS:"
    echo "File:       $FILENAME"
    echo "Duration:   $SRC_DUR sec"
    echo "Size:       ${SRC_SIZE_MB} MB ($SRC_SIZE_BYTES bytes)"
    echo "Resolution: ${SRC_W}x${SRC_H}"
    echo "FPS:        $SRC_FPS"
    echo "Bitrate:    ${SRC_BITRATE_KBPS} kbps"
    echo "======================================================================"
    echo ""
} > "$REPORT_FILE"

# ------------------------------------------------------------------------------
# 3. إعداد الجودات الذكية (Smart Ladder)
# ------------------------------------------------------------------------------
# القواعد:
# - مدة القطعة: 4 ثواني
# - GOP: 4 ثواني (محاذى)
# - الترتيب: فقط ما يسمح به المصدر
SEG_TIME=4
GOP_SIZE=$(calc "int($SRC_FPS * $SEG_TIME)")

declare -a QUALITIES

# إضافة الجودات فقط إذا كان المصدر يسمح بذلك
if [ "$SRC_H" -ge 1080 ]; then
    # Name Width Bitrate MaxRate BufSize CRF
    QUALITIES+=("1080p 1920 4500k 5000k 7500k 28")
fi

if [ "$SRC_H" -ge 720 ]; then
    QUALITIES+=("720p 1280 2500k 2800k 4200k 28")
fi

# 480p دائماً موجودة
QUALITIES+=("480p 854 800k 1000k 2000k 28")

# تنظيف الماستر القديم
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-INDEPENDENT-SEGMENTS" >> "$OUTPUT_DIR/master.m3u8"

# ------------------------------------------------------------------------------
# 4. المعالجة (Processing Loop)
# ------------------------------------------------------------------------------
echo ">> [2/4] Transcoding Started..."
TOTAL_START=$(date +%s)

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH TARGET_BITRATE MAXRATE BUFSIZE CRF_VAL <<< "$quality"
    
    # تجهيز المجلد
    VARIANT_DIR="$OUTPUT_DIR/$NAME"
    mkdir -p "$VARIANT_DIR"
    
    echo "--------------------------------------------------------"
    echo " Processing Quality: $NAME ($WIDTH x Height)"
    echo "--------------------------------------------------------"

    Q_START=$(date +%s)

    # ========================== FFmpeg Command ==========================
    # تم تطبيق إعداداتك بحذافيرها مع هيكلية المجلدات
    ffmpeg -y -hide_banner -loglevel error -nostdin \
        -i "$INPUT_FILE" \
        -vf "scale=w=${WIDTH}:h=-2:flags=lanczos" \
        -c:v libx264 -profile:v high -preset veryslow -tune animation -crf "$CRF_VAL" \
        -b:v "$TARGET_BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -force_key_frames "expr:gte(t,n_forced*$SEG_TIME)" \
        -flags +cgop \
        \
        -c:a aac -b:a 128k -ac 2 \
        \
        -hls_time "$SEG_TIME" \
        -hls_playlist_type vod \
        -hls_segment_type mpegts \
        -hls_flags independent_segments \
        -hls_segment_filename "$VARIANT_DIR/seg_%03d.ts" \
        "$VARIANT_DIR/index.m3u8"
    # ====================================================================

    Q_END=$(date +%s)
    Q_DURATION=$(($Q_END - $Q_START))
    
    # ------------------------------------------------------------------
    # 5. التحليل الجنائي للجودة (Forensics)
    # ------------------------------------------------------------------
    echo "   -> Analyzing output..."
    
    # أ) الحجم والملفات
    TOTAL_Q_SIZE=$(stat -c%s "$VARIANT_DIR"/seg_*.ts 2>/dev/null | awk '{s+=$1} END {print s+0}')
    SEG_COUNT=$(ls "$VARIANT_DIR"/seg_*.ts 2>/dev/null | wc -l)
    
    # ب) البت ريت الحقيقي
    REAL_BITRATE_BPS=$(calc "int(($TOTAL_Q_SIZE * 8) / $SRC_DUR)")
    REAL_BITRATE_KBPS=$(calc "int($REAL_BITRATE_BPS / 1000)")
    
    # ج) الذروة (Peak Bitrate) والمتوسط (Average)
    MAX_SEG_BYTES=$(ls -lS "$VARIANT_DIR"/seg_*.ts 2>/dev/null | head -n 1 | awk '{print $5}')
    if [ -z "$MAX_SEG_BYTES" ]; then MAX_SEG_BYTES=0; fi
    PEAK_BITRATE_BPS=$(calc "int(($MAX_SEG_BYTES * 8) / $SEG_TIME)")
    PEAK_BITRATE_KBPS=$(calc "int($PEAK_BITRATE_BPS / 1000)")
    
    # د) حساب I-Frames و P-Frames (تحليل أول 3 قطع لتوفير الوقت أو تحليل الكل)
    # لتحليل دقيق، سنفحص الملفات الناتجة باستخدام ffprobe
    # ملاحظة: هذا قد يستغرق وقتاً إذا كان الفيديو طويلاً جداً
    echo "   -> Counting Frame Types (I/P)..."
    FRAME_STATS=$(ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -of csv=p=0 "$VARIANT_DIR"/seg_*.ts 2>/dev/null | sort | uniq -c)
    I_FRAMES=$(echo "$FRAME_STATS" | grep "I" | awk '{print $1}')
    P_FRAMES=$(echo "$FRAME_STATS" | grep "P" | awk '{print $1}')
    if [ -z "$I_FRAMES" ]; then I_FRAMES=0; fi
    if [ -z "$P_FRAMES" ]; then P_FRAMES=0; fi

    # هـ) الحسابات الرياضية
    COMPRESSION_RATIO=$(calc "$SRC_SIZE_BYTES / $TOTAL_Q_SIZE")
    SPEED_X=$(calc "$SRC_DUR / $Q_DURATION")
    if [ "$Q_DURATION" -eq 0 ]; then SPEED_X="N/A"; fi
    
    REDUCTION_PCT=$(calc "100 - ($TOTAL_Q_SIZE * 100 / $SRC_SIZE_BYTES)")
    
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$VARIANT_DIR/seg_000.ts" 2>/dev/null)
    if [ -z "$ACTUAL_H" ]; then ACTUAL_H=$WIDTH; fi # Fallback
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$REAL_BITRATE_BPS / ($PIXELS * $SRC_FPS)")
    
    # و) حساب Overhead
    # نفترض حجم الفيديو الخام (H.264 stream) ونقارنه بـ TS container
    STREAM_ONLY_BITS=$(calc "($REAL_BITRATE_BPS * $SRC_DUR)") 
    # هذه قيمة تقريبية لأننا لا نستطيع فصل الحاوية بسهولة بدون demux
    # سنحسب الـ TS Packet Overhead نظرياً (كل 188 بايت فيها 4 بايت هيدر)
    # المعادلة التقريبية للـ TS Overhead هي حوالي 5-10%
    OVERHEAD_BYTES=$(calc "$TOTAL_Q_SIZE * 0.08") # تقدير 8%
    OVERHEAD_KB=$(calc "int($OVERHEAD_BYTES / 1024)")

    # ز) سرعة الترميز (Encoding FPS) - FBS
    ENCODING_FPS=$(calc "($SRC_FPS * $SRC_DUR) / $Q_DURATION")

    # كتابة التقرير التفصيلي للجودة
    {
        echo "--------------------------------------------------"
        echo " QUALITY: $NAME"
        echo "--------------------------------------------------"
        echo "Time Taken:       ${Q_DURATION} sec"
        echo "Comp. Ratio:      ${COMPRESSION_RATIO}:1"
        echo "Speed Factor:     ${SPEED_X}x"
        echo "Total Size:       $(calc "$TOTAL_Q_SIZE/1024/1024") MB"
        echo "Segments:         $SEG_COUNT"
        echo "I-Frames:         $I_FRAMES"
        echo "P-Frames:         $P_FRAMES"
        echo "Est. Overhead:    ${OVERHEAD_KB} KB"
        echo "Bitrate (Avg):    ${REAL_BITRATE_KBPS} kbps"
        echo "Bitrate (Peak):   ${PEAK_BITRATE_KBPS} kbps"
        echo "Target Bitrate:   $(echo $TARGET_BITRATE | tr -d 'k') kbps"
        echo "Reduction:        ${REDUCTION_PCT}%"
        echo "BPP:              $BPP"
        echo "FBS (Enc FPS):    $ENCODING_FPS"
        echo ""
    } >> "$REPORT_FILE"

    # إضافة للمسار الرئيسي (Master Playlist)
    # نضيف هامش أمان 10% للـ Bandwidth
    SAFE_PEAK_BW=$(calc "int($PEAK_BITRATE_BPS * 1.10)")
    SAFE_AVG_BW=$(calc "int($REAL_BITRATE_BPS * 1.05)")

    printf "#EXT-X-STREAM-INF:BANDWIDTH=%d,AVERAGE-BANDWIDTH=%d,RESOLUTION=%sx%s,CODECS=\"avc1.640028,mp4a.40.2\"\n%s/index.m3u8\n" \
        "$SAFE_PEAK_BW" "$SAFE_AVG_BW" "$WIDTH" "$ACTUAL_H" "$NAME" >> "$OUTPUT_DIR/master.m3u8"

done

# ------------------------------------------------------------------------------
# 6. الخاتمة
# ------------------------------------------------------------------------------
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(($TOTAL_END - $TOTAL_START))
FORMATTED_TIME=$(printf '%02dh:%02dm:%02ds\n' $(($TOTAL_ELAPSED/3600)) $(($TOTAL_ELAPSED%3600/60)) $(($TOTAL_ELAPSED%60)))

{
    echo "======================================================================"
    echo "OVERALL PERFORMANCE:"
    echo "Total Job Time:   $FORMATTED_TIME"
    echo "Total Qualities:  ${#QUALITIES[@]}"
    echo "======================================================================"
} >> "$REPORT_FILE"

echo ">> [4/4] Done. Detailed Report saved to: $REPORT_FILE"