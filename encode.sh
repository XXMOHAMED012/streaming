#!/bin/bash

# التحقق من المدخلات
if [ -z "$1" ]; then
    echo "Usage: ./encode_lesson.sh <input_video.mp4>"
    exit 1
fi

INPUT="$1"
FILENAME=$(basename -- "$INPUT")
BASENAME="${FILENAME%.*}"
OUTPUT_DIR="./output_${BASENAME}"

mkdir -p "$OUTPUT_DIR"

# 1. استخراج الارتفاع والفريم ريت
# نحتاج الفريم ريت بدقة لحساب الـ GOP (مثلاً لو كان 29.97 يختلف عن 30)
SOURCE_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT")
SOURCE_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" | bc -l)
# تقريب الفريم ريت لأقرب رقم صحيح للعمليات الحسابية البسيطة (أو تركه كما هو وحسابه ب bc)
# للتبسيط سنفترض هنا التعامل مع integer في الـ GOP calculation لكن الأفضل استخدام fps الأصلي
# سنستخدم خدعة keyint_min مساوي لـ g لضمان الثبات

echo ">> Source: ${SOURCE_HEIGHT}p @ ${SOURCE_FPS}fps"

SEGMENT_TIME=10
# حساب عدد الفريمات في الـ 10 ثواني بدقة (باستخدام python للحساب الدقيق للفواصل العشرية)
GOP_SIZE=$(python3 -c "print(int(float($SOURCE_FPS) * $SEGMENT_TIME))")

echo ">> Calculated GOP Size: $GOP_SIZE frames (strictly every $SEGMENT_TIME seconds)"

PRESET="veryslow"
TUNE="animation"

# تنظيف الماستر
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"

# مصفوفة الجودات
declare -a QUALITIES
if [ "$SOURCE_HEIGHT" -ge 1080 ]; then
    QUALITIES+=("1080p 1920 2500k 3000k")
fi
if [ "$SOURCE_HEIGHT" -ge 720 ]; then
    QUALITIES+=("720p 1280 1400k 1800k")
fi
QUALITIES+=("480p 854 600k 900k")

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH BITRATE MAXRATE <<< "$quality"
    
    echo "Processing $NAME..."
    
    # أهم سطر: forcing keyframes
    # -sc_threshold 0: يمنع الإنكودر من وضع كي-فريم عند تغير المشهد
    # -g $GOP_SIZE: يضع كي-فريم كل X فريم
    # -keyint_min $GOP_SIZE: يمنعه من وضع كي-فريم قبل الموعد
    # -force_key_frames: تأكيد إضافي (اختياري لكن مفيد) لوضع فريمات عند التوقيتات
    
    ffmpeg -y -hide_banner -loglevel error -stats \
        -i "$INPUT" \
        -vf "scale=w=${WIDTH}:h=-2" \
        -c:v libx264 -preset "$PRESET" -tune "$TUNE" -crf 23 \
        -b:v "$BITRATE" -maxrate "$MAXRATE" -bufsize "$((2 * ${MAXRATE%k} ))k" \
        -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEGMENT_TIME" \
        -hls_playlist_type vod \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8"

    # إضافة للماستر
    BANDWIDTH=$((${MAXRATE%k} * 1000))
    echo "#EXT-X-STREAM-INF:BANDWIDTH=$BANDWIDTH,RESOLUTION=${WIDTH}x..." >> "$OUTPUT_DIR/master.m3u8"
    echo "${NAME}.m3u8" >> "$OUTPUT_DIR/master.m3u8"
done

echo ">> Done."