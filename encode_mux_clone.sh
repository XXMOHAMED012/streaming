#!/bin/bash

# ==============================================================================
#  MASTER ENCODER V5: Mux Clone Edition (Seamless Failover Optimized)
# ==============================================================================

if [ -z "$1" ]; then
    echo "Usage: ./encode_master.sh <input_video.mp4>"
    exit 1
fi

export LC_NUMERIC="C"
INPUT_FILE=$(realpath "$1")
FILENAME=$(basename -- "$INPUT_FILE")
OUTPUT_DIR=$(pwd)
REPORT_FILE="$OUTPUT_DIR/REPORT_MASTER.txt"

command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo >&2 "Error: 'ffprobe' is required."; exit 1; }

calc() { awk "BEGIN { print $* }" 2>/dev/null || echo "0"; }

# ------------------------------------------------------------------------------
# 1. Source Analysis
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

{
    echo "======================================================================"
    echo "                     MASTER ENCODING REPORT (Mux Clone)"
    echo "======================================================================"
    echo "ORIGINAL FILE METRICS:"
    echo "File:       $FILENAME"
    echo "Duration:   $SRC_DUR sec"
    echo "Resolution: ${SRC_W}x${SRC_H}"
    echo "FPS:        $SRC_FPS"
    echo "Bitrate:    ${SRC_BITRATE_KBPS} kbps"
    echo "======================================================================"
    echo ""
} > "$REPORT_FILE"

# ------------------------------------------------------------------------------
# 2. Mux-Matched Settings
# ------------------------------------------------------------------------------
# تم التعديل ليطابق تحليل Mux (5 ثواني)
SEG_TIME=5
GOP_SIZE=$(calc "int($SRC_FPS * $SEG_TIME)")

declare -a QUALITIES

# ملاحظة: قمنا بتقليل البت ريت ليقترب من Mux، مع الحفاظ على هامش جودة أعلى قليلاً
# Format: NAME WIDTH TARGET MAX BUF CRF

if [ "$SRC_H" -ge 1080 ]; then
    # 1080p (Mux usually doesn't output this for basic plans, but we will keeping it optimized)
    QUALITIES+=("1080p 1920 3500k 4500k 6000k 26")
fi

if [ "$SRC_H" -ge 720 ]; then
    # Mux was ~500k. We use 800k-1200k to be safe for sports/action
    QUALITIES+=("720p 1280 1200k 1800k 3000k 27")
fi

# Mux Standard: 480p
QUALITIES+=("480p 854 600k 900k 1500k 28")

# Mux Low-End: 270p (Adding this as per Mux analysis)
QUALITIES+=("270p 480 300k 500k 800k 28")

rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-INDEPENDENT-SEGMENTS" >> "$OUTPUT_DIR/master.m3u8"

# ------------------------------------------------------------------------------
# 3. Processing
# ------------------------------------------------------------------------------
echo ">> [2/4] Transcoding Started..."
TOTAL_START=$(date +%s)

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH TARGET_BITRATE MAXRATE BUFSIZE CRF_VAL <<< "$quality"
    
    VARIANT_DIR="$OUTPUT_DIR/$NAME"
    mkdir -p "$VARIANT_DIR"
    
    echo "--------------------------------------------------------"
    echo " Processing Quality: $NAME ($WIDTH x Height)"
    echo "--------------------------------------------------------"

    Q_START=$(date +%s)

    # ========================== FFmpeg Command ==========================
    # Added -bf 3 to increase B-frames usage (Matching Mux efficiency)
    ffmpeg -y -hide_banner -loglevel error -nostdin \
        -i "$INPUT_FILE" \
        -vf "scale=w=${WIDTH}:h=-2:flags=lanczos" \
        -c:v libx264 -profile:v high -preset veryslow -tune animation -crf "$CRF_VAL" \
        -b:v "$TARGET_BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -force_key_frames "expr:gte(t,n_forced*$SEG_TIME)" \
        -flags +cgop \
        -bf 3 \
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
    # 4. Forensics & Reporting
    # ------------------------------------------------------------------
    echo "   -> Analyzing output..."
    
    # Size & Bitrate
    TOTAL_Q_SIZE=$(stat -c%s "$VARIANT_DIR"/seg_*.ts 2>/dev/null | awk '{s+=$1} END {print s+0}')
    SEG_COUNT=$(ls "$VARIANT_DIR"/seg_*.ts 2>/dev/null | wc -l)
    
    REAL_BITRATE_BPS=$(calc "int(($TOTAL_Q_SIZE * 8) / $SRC_DUR)")
    REAL_BITRATE_KBPS=$(calc "int($REAL_BITRATE_BPS / 1000)")
    
    MAX_SEG_BYTES=$(ls -lS "$VARIANT_DIR"/seg_*.ts 2>/dev/null | head -n 1 | awk '{print $5}')
    if [ -z "$MAX_SEG_BYTES" ]; then MAX_SEG_BYTES=0; fi
    PEAK_BITRATE_BPS=$(calc "int(($MAX_SEG_BYTES * 8) / $SEG_TIME)")
    PEAK_BITRATE_KBPS=$(calc "int($PEAK_BITRATE_BPS / 1000)")

    # Frame Counting
    echo "   -> Counting Frames..."
    cat "$VARIANT_DIR"/seg_*.ts | ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -of csv=p=0 - > "$VARIANT_DIR/frames_dump.txt"
    
    I_FRAMES=$(grep -c "I" "$VARIANT_DIR/frames_dump.txt")
    P_FRAMES=$(grep -c "P" "$VARIANT_DIR/frames_dump.txt")
    B_FRAMES=$(grep -c "B" "$VARIANT_DIR/frames_dump.txt")
    TOTAL_FRAMES=$(($I_FRAMES + $P_FRAMES + $B_FRAMES))
    rm -f "$VARIANT_DIR/frames_dump.txt"

    # Stats
    COMPRESSION_RATIO=$(calc "$SRC_SIZE_BYTES / $TOTAL_Q_SIZE")
    SPEED_X=$(calc "$SRC_DUR / $Q_DURATION")
    if [ "$Q_DURATION" -eq 0 ]; then SPEED_X="N/A"; fi
    
    ACTUAL_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$VARIANT_DIR/seg_000.ts" 2>/dev/null)
    if [ -z "$ACTUAL_H" ]; then ACTUAL_H=$WIDTH; fi 
    PIXELS=$(calc "$WIDTH * $ACTUAL_H")
    BPP=$(calc "$REAL_BITRATE_BPS / ($PIXELS * $SRC_FPS)")
    
    OVERHEAD_BYTES=$(calc "$TOTAL_Q_SIZE * 0.08")
    OVERHEAD_KB=$(calc "int($OVERHEAD_BYTES / 1024)")

    {
        echo "--------------------------------------------------"
        echo " QUALITY: $NAME"
        echo "--------------------------------------------------"
        echo "Time:             ${Q_DURATION} sec"
        echo "Size:             $(calc "$TOTAL_Q_SIZE/1024/1024") MB"
        echo "Segments:         $SEG_COUNT"
        echo "Frames (I/P/B):   $I_FRAMES / $P_FRAMES / $B_FRAMES"
        echo "Target Bitrate:   $(echo $TARGET_BITRATE | tr -d 'k') kbps"
        echo "Actual Bitrate:   ${REAL_BITRATE_KBPS} kbps"
        echo "Peak Bitrate:     ${PEAK_BITRATE_KBPS} kbps"
        echo "BPP:              $BPP"
        echo ""
    } >> "$REPORT_FILE"

    SAFE_PEAK_BW=$(calc "int($PEAK_BITRATE_BPS * 1.10)")
    SAFE_AVG_BW=$(calc "int($REAL_BITRATE_BPS * 1.05)")

    printf "#EXT-X-STREAM-INF:BANDWIDTH=%d,AVERAGE-BANDWIDTH=%d,RESOLUTION=%sx%s,CODECS=\"avc1.640028,mp4a.40.2\"\n%s/index.m3u8\n" \
        "$SAFE_PEAK_BW" "$SAFE_AVG_BW" "$WIDTH" "$ACTUAL_H" "$NAME" >> "$OUTPUT_DIR/master.m3u8"

done

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(($TOTAL_END - $TOTAL_START))
FORMATTED_TIME=$(printf '%02dh:%02dm:%02ds\n' $(($TOTAL_ELAPSED/3600)) $(($TOTAL_ELAPSED%3600/60)) $(($TOTAL_ELAPSED%60)))

{
    echo "======================================================================"
    echo "Total Job Time:   $FORMATTED_TIME"
    echo "======================================================================"
} >> "$REPORT_FILE"

echo ">> [4/4] Done. Report: $REPORT_FILE"