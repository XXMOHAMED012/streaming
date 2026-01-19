#!/bin/bash

# ==============================================================================
#  FULL VIDEO QUALITY AUDIT (HLS vs REFERENCE)
# ==============================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: ./quality_lab_full.sh <original_reference.mp4> <playlist.m3u8>"
    echo "Example: ./quality_lab_full.sh almfkr502.mp4 ./results_almfkr502/1080p.m3u8"
    exit 1
fi

REF="$1"
PLAYLIST="$2"
BASENAME=$(basename -- "$PLAYLIST")
# اسم المجلد الخاص بالتقارير
REPORT_DIR="./quality_reports"
# تقرير خاص للفحص الكامل
REPORT_FILE="$REPORT_DIR/FULL_REPORT_${BASENAME%.*}.txt"

VMAF_JSON="$REPORT_DIR/vmaf_full.json"
SSIM_LOG="$REPORT_DIR/ssim_full.log"
PSNR_LOG="$REPORT_DIR/psnr_full.log"

command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' is required."; exit 1; }

mkdir -p "$REPORT_DIR"
rm -f "$VMAF_JSON" "$SSIM_LOG" "$PSNR_LOG"

echo "--------------------------------------------------------"
echo ">> [INIT] Reference: $REF"
echo ">> [INIT] Playlist:  $PLAYLIST"
echo "--------------------------------------------------------"

echo ">> [1/4] Checking Environment..."

HAS_VMAF=$(ffmpeg -filters 2>/dev/null | grep libvmaf)
if [ -z "$HAS_VMAF" ]; then
    echo "!! WARNING: No libvmaf found. Mode: STRUCTURAL ONLY."
    MODE="STRUCTURAL"
else
    echo ">> VMAF Detected. Mode: FULL ANALYTICS."
    MODE="FULL"
    VMAF_MODEL_PATH="$REPORT_DIR/vmaf_v0.6.1.json"
    if [ ! -f "$VMAF_MODEL_PATH" ]; then
        echo ">> Downloading VMAF Model..."
        wget -q -O "$VMAF_MODEL_PATH" https://github.com/Netflix/vmaf/raw/master/model/vmaf_v0.6.1.json
    fi
fi

echo ">> [2/4] Configuring Engines..."

# استخراج خصائص الفيديو الأصلي لتوحيد المقاييس
REF_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$REF")
REF_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$REF")
REF_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$REF")

# الفلاتر السحرية لتوحيد الزمن والأبعاد
# fps: توحيد الإطارات
# settb: توحيد القاعدة الزمنية
# setpts: تصفير العداد لضمان البدء من الصفر
COMMON_FILTERS="fps=${REF_FPS},settb=AVTB,setpts=PTS-STARTPTS"

if [ "$MODE" == "FULL" ]; then
    FILTER_COMPLEX="[0:v]${COMMON_FILTERS},split=3[ref1][ref2][ref3]; \
    [1:v]${COMMON_FILTERS},scale=${REF_W}:${REF_H}:flags=bicubic,split=3[dist1][dist2][dist3]; \
    [dist1][ref1]libvmaf=model=path=${VMAF_MODEL_PATH}:log_path=${VMAF_JSON}:log_fmt=json:n_threads=4[vmaf_out]; \
    [dist2][ref2]ssim=stats_file=${SSIM_LOG}[ssim_out]; \
    [dist3][ref3]psnr=stats_file=${PSNR_LOG}[psnr_out]"
    
    MAP_CMD="-map [vmaf_out] -map [ssim_out] -map [psnr_out]"
else
    FILTER_COMPLEX="[0:v]${COMMON_FILTERS},split=2[ref1][ref2]; \
    [1:v]${COMMON_FILTERS},scale=${REF_W}:${REF_H}:flags=bicubic,split=2[dist1][dist2]; \
    [dist1][ref1]ssim=stats_file=${SSIM_LOG}[ssim_out]; \
    [dist2][ref2]psnr=stats_file=${PSNR_LOG}[psnr_out]"
    
    MAP_CMD="-map [ssim_out] -map [psnr_out]"
fi

echo ">> [3/4] Running Full Analysis (This will take time)..."

# نمرر ملف الـ m3u8 كمدخل ثاني. ffmpeg سيعالجه كفيديو كامل متصل.
# -shortest: مهم جداً لإيقاف المقارنة إذا كان أحد الفيديوهات أقصر من الآخر (لتجنب حساب الشاشة السوداء)
ffmpeg -hide_banner -stats \
    -i "$REF" \
    -i "$PLAYLIST" \
    -filter_complex "$FILTER_COMPLEX" \
    $MAP_CMD \
    -shortest \
    -f null - 

RETCODE=$?
if [ $RETCODE -ne 0 ]; then
    echo "!!!! CRITICAL ERROR: Analysis failed."
    exit 1
fi

echo ""
echo ">> [4/4] Generating Final Report..."

# دالة لحساب المتوسطات
get_avg() {
    if [ -f "$1" ]; then
        grep -oP "$2" "$1" | awk '{ total += $1; count++ } END { if(count>0) print total/count; else print "0" }'
    else
        echo "0"
    fi
}

# دالة لاستخراج أسوأ قيمة (Minimum)
get_min() {
    if [ -f "$1" ]; then
        grep -oP "$2" "$1" | sort -n | head -1
    else
        echo "N/A"
    fi
}

if [ "$MODE" == "FULL" ] && [ -f "$VMAF_JSON" ]; then
    if command -v jq >/dev/null 2>&1; then
        VMAF_MEAN=$(jq '.pooled_metrics.vmaf.mean' "$VMAF_JSON" 2>/dev/null)
        VMAF_MIN=$(jq '.pooled_metrics.vmaf.min' "$VMAF_JSON" 2>/dev/null)
    else
        VMAF_MEAN=$(grep -oP '"mean":\s*\K[0-9.]+' "$VMAF_JSON" | head -1)
        VMAF_MIN="N/A (jq missing)"
    fi
    if [ -z "$VMAF_MEAN" ] || [ "$VMAF_MEAN" == "null" ]; then VMAF_MEAN="0"; fi
else
    VMAF_MEAN="N/A"
    VMAF_MIN="N/A"
fi

SSIM_MEAN=$(get_avg "$SSIM_LOG" 'Y:\K[0-9.]+')
SSIM_MIN=$(get_min "$SSIM_LOG" 'Y:\K[0-9.]+')

PSNR_MEAN=$(get_avg "$PSNR_LOG" 'y:\K[0-9.]+')

# كتابة التقرير
{
    echo "####################################################################"
    echo "             FULL VIDEO AUDIT REPORT (END-TO-END)"
    echo "####################################################################"
    echo "Date: $(date)"
    echo "Reference File: $REF"
    echo "Playlist File:  $PLAYLIST"
    echo "--------------------------------------------------------------------"
    
    if [ "$MODE" == "FULL" ]; then
        echo "1. VMAF METRICS (Visual Perception)"
        echo "   • Mean Score:      $VMAF_MEAN / 100"
        echo "   • Minimum Score:   $VMAF_MIN / 100 (Worst moment)"
        echo "--------------------------------------------------------------------"
    fi

    echo "2. SSIM METRICS (Structural Integrity)"
    echo "   • Mean Y-SSIM:     $SSIM_MEAN / 1.0000"
    echo "   • Min Y-SSIM:      $SSIM_MIN / 1.0000"
    echo "--------------------------------------------------------------------"
    echo "3. PSNR METRICS"
    echo "   • Mean Y-PSNR:     $PSNR_MEAN dB"
    echo "####################################################################"
} > "$REPORT_FILE"

echo ">> Full Audit Complete."
echo ">> Report: $REPORT_FILE"
cat "$REPORT_FILE"