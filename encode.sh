#!/bin/bash

# التحقق من وجود ملف
if [ -z "$1" ]; then
    echo "Usage: ./encode_lesson.sh <input_video.mp4>"
    exit 1
fi

INPUT="$1"
FILENAME=$(basename -- "$INPUT")
BASENAME="${FILENAME%.*}"
OUTPUT_DIR="./output_${BASENAME}"

# إنشاء مجلد للمخرجات
mkdir -p "$OUTPUT_DIR"

# 1. استخراج ارتفاع الفيديو الأصلي (Height)
SOURCE_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$INPUT")
echo ">> Detected Source Height: ${SOURCE_HEIGHT}p"

# 2. إعداد المتغيرات الأساسية
# بما أن المحتوى تعليمي (قليل الحركة)، سنستخدم Bitrate منخفض جداً مقارنة بالأفلام
# GOP = 10 seconds * 30 fps (approx) = 300 frames (سنثبته بالثواني لضمان الدقة)
SEGMENT_TIME=10
GOP_SIZE=300 # assuming 30fps usually, or using keyint_min
PRESET="veryslow"
TUNE="animation" # خيار ممتاز للشروحات والوايت بورد

# بداية تكوين أمر FFMPEG
# سنستخدم filter_complex لتقسيم الفيديو لعدة نسخ
CMD="ffmpeg -i \"$INPUT\" -filter_complex"
MAPS=""
VAR_STREAM_MAP=""

# بناء الفلاتر والخرائط بناءً على دقة المصدر

# ----------------- 1080p Logic -----------------
if [ "$SOURCE_HEIGHT" -ge 1080 ]; then
    echo ">> Will generate 1080p..."
    # نستخدم split إذا كان هناك جودات أقل، وإلا نستخدمه مباشرة
    # لكن للتبسيط في filter_complex سنقوم بعمل chain
    FILTER_CHAINS+="[0:v]scale=1920:1080:force_original_aspect_ratio=decrease[v1080];"
    
    CMD+=" -map \"[v1080]\" -c:v:0 libx264 -b:v:0 2500k -maxrate:v:0 3000k -bufsize:v:0 5000k -map 0:a -c:a:0 aac -b:a:0 128k "
    # إضافة settings خاصة للـ 1080
    VAR_STREAM_MAP+="v:0,a:0,name:1080p "
fi

# ----------------- 720p Logic -----------------
if [ "$SOURCE_HEIGHT" -ge 720 ]; then
    echo ">> Will generate 720p..."
    FILTER_CHAINS+="[0:v]scale=1280:720:force_original_aspect_ratio=decrease[v720];"
    
    # تحديد الاندكس بناء على ما تم إضافته سابقاً أمر معقد قليلاً في سطر واحد ديناميكي
    # لذلك سنستخدم طريقة أبسط: أوامر منفصلة لكن داخل نفس السكربت، أو استخدام stream_map المعقدة.
    # لضمان عدم تعقيد السكربت عليك وتجنب أخطاء الـ mapping الديناميكي، 
    # سأقوم بتبسيط الاستراتيجية: إنشاء الجودات، ثم دمجها في Playlist.
    # الأمر الواحد (Single Command) مع الشرط الديناميكي في Bash معقد جداً في الصيانة.
    # سأكتب لك الطريقة الأكثر استقراراً: حلقة تكرار (Loop).
fi

# --- إعادة بناء الاستراتيجية لتكون أكثر استقراراً ووضوحاً ---
# سنقوم بتنفيذ أمر ffmpeg ذكي يقوم بإنتاج كل الجودات المتاحة بناء على المصدر

# تعريف المصفوفات للإعدادات: (الاسم الارتفاع البت-ريت الماكس-ريت)
# لاحظ أن البت ريت منخفض لأننا نستخدم tune animation + veryslow
declare -a QUALITIES
if [ "$SOURCE_HEIGHT" -ge 1080 ]; then
    QUALITIES+=("1080p 1920 2500k 3000k")
fi
if [ "$SOURCE_HEIGHT" -ge 720 ]; then
    QUALITIES+=("720p 1280 1400k 1800k")
fi
# دائما ننتج 480
QUALITIES+=("480p 854 600k 900k")

echo ">> Starting transcoding with preset: $PRESET and tune: $TUNE"
echo ">> Output directory: $OUTPUT_DIR"

# تنظيف ملف الماستر القديم
rm -f "$OUTPUT_DIR/master.m3u8"
echo "#EXTM3U" > "$OUTPUT_DIR/master.m3u8"
echo "#EXT-X-VERSION:3" >> "$OUTPUT_DIR/master.m3u8"

for quality in "${QUALITIES[@]}"; do
    read -r NAME WIDTH BITRATE MAXRATE <<< "$quality"
    
    echo "------------------------------------------------"
    echo "Processing $NAME ($WIDTH x Height) @ $BITRATE ..."
    
    # حساب الارتفاع للحفاظ على النسبة (Height = -2 يعني احسب تلقائياً مع الحفاظ على القسمة على 2)
    SCALE_CMD="scale=w=${WIDTH}:h=-2"
    
    # تنفيذ الأمر
    ffmpeg -y -hide_banner -loglevel error -stats \
        -i "$INPUT" \
        -vf "$SCALE_CMD" \
        -c:v libx264 -preset "$PRESET" -tune "$TUNE" -crf 23 \
        -b:v "$BITRATE" -maxrate "$MAXRATE" -bufsize "$((2 * ${MAXRATE%k} ))k" \
        -g $((SEGMENT_TIME * 30)) -keyint_min $((SEGMENT_TIME * 30)) -sc_threshold 0 \
        -c:a aac -b:a 128k -ac 2 \
        -hls_time "$SEGMENT_TIME" -hls_playlist_type vod \
        -hls_segment_filename "$OUTPUT_DIR/${NAME}_%03d.ts" \
        "$OUTPUT_DIR/${NAME}.m3u8"

    # إضافة الجودة لملف الماستر
    # نحتاج لمعرفة الباندويث بالبت (نضرب في 1000 تقريباً)
    BANDWIDTH=$((${MAXRATE%k} * 1000))
    
    echo "#EXT-X-STREAM-INF:BANDWIDTH=$BANDWIDTH,RESOLUTION=${WIDTH}x..." >> "$OUTPUT_DIR/master.m3u8" # الدقة هنا تقريبية في الهيدر
    echo "${NAME}.m3u8" >> "$OUTPUT_DIR/master.m3u8"
done

echo "------------------------------------------------"
echo ">> Done! All files are in $OUTPUT_DIR"
echo ">> Master playlist created at $OUTPUT_DIR/master.m3u8"