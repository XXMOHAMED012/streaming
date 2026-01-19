#!/bin/bash

# ==============================================================================
#  QUALITY FORENSICS LAB: VMAF, SSIM, PSNR Deep Analysis
# ==============================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: ./quality_lab.sh <original_reference.mp4> <encoded_version.ts>"
    echo "Example: ./quality_lab.sh raw_video.mp4 ./output/1080p_000.ts"
    exit 1
fi

REF="$1"
DIST="$2"
BASENAME=$(basename -- "$DIST")
REPORT_DIR="./quality_reports"
REPORT_FILE="$REPORT_DIR/REPORT_${BASENAME%.*}.txt"
VMAF_JSON="$REPORT_DIR/vmaf_raw.json"
SSIM_LOG="$REPORT_DIR/ssim_raw.log"
PSNR_LOG="$REPORT_DIR/psnr_raw.log"

# التأكد من وجود أدوات
command -v jq >/dev/null 2>&1 || { echo >&2 "Error: 'jq' tool is required. Install with 'sudo apt install jq'"; exit 1; }
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' tool is required."; exit 1; }

mkdir -p "$REPORT_DIR"

# --- 1. إعداد موديل VMAF ---
# سنقوم بتحميل الموديل الرسمي إذا لم يكن موجوداً
VMAF_MODEL_PATH="$REPORT_DIR/vmaf_v0.6.1.json"
if [ ! -f "$VMAF_MODEL_PATH" ]; then
    echo ">> VMAF Model not found. Downloading v0.6.1..."
    wget -q -O "$VMAF_MODEL_PATH" https://github.com/Netflix/vmaf/raw/master/model/vmaf_v0.6.1.json
fi

# --- 2. تجهيز الفلاتر المعقدة ---
echo ">> [1/3] Preparing Forensics Analysis (This may take time)..."

# نحتاج لمعرفة أبعاد الأصل لنقوم بعمل Upscale للنسخة المضغوطة لتطابق الأصل قبل المقارنة
REF_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=s=x:p=0 "$REF")
REF_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$REF")

# الأمر السحري: Upscale -> VMAF + SSIM + PSNR في أمر واحد
# نستخدم bicubic للـ upscale لأنه المعيار المعتمد في اختبارات Netflix
FILTER_COMPLEX="[1:v]scale=${REF_W}:${REF_H}:flags=bicubic[dist_scaled]; \
[dist_scaled][0:v]libvmaf=model_path=${VMAF_MODEL_PATH}:log_path=${VMAF_JSON}:log_fmt=json:n_threads=4[vmaf_out]; \
[dist_scaled][0:v]ssim=stats_file=${SSIM_LOG}[ssim_out]; \
[dist_scaled][0:v]psnr=stats_file=${PSNR_LOG}[psnr_out]"

# --- 3. تشغيل المحرك ---
# ملاحظة: نستخدم -map لنأخذ المخرجات من الفلاتر ونتخلص منها (f null) لأننا نريد اللوجات فقط
ffmpeg -hide_banner -stats \
    -i "$REF" \
    -i "$DIST" \
    -filter_complex "$FILTER_COMPLEX" \
    -map "[vmaf_out]" -map "[ssim_out]" -map "[psnr_out]" \
    -f null - 2>/dev/null

echo ">> [2/3] Analyzing Raw Data..."

# --- 4. استخراج البيانات وتحليلها ---

# A. تحليل VMAF (باستخدام jq)
VMAF_SCORE=$(jq '.pooled_metrics.vmaf.mean' "$VMAF_JSON")
VMAF_MIN=$(jq '.pooled_metrics.vmaf.min' "$VMAF_JSON")
# 1% Low (أسوأ 1% من الفريمات - مهم جداً لاكتشاف التقطيع اللحظي)
VMAF_1_PERCENTILE=$(jq '.pooled_metrics.vmaf.harmonic_mean' "$VMAF_JSON") 

# B. تحليل SSIM
# استخراج المتوسط (Y channel only because eyes are sensitive to Luma)
SSIM_Y=$(grep -oP 'Y:\K[0-9.]+' "$SSIM_LOG" | awk '{ total += $1; count++ } END { print total/count }')
# استخراج أسوأ فريم
SSIM_MIN=$(grep -oP 'Y:\K[0-9.]+' "$SSIM_LOG" | sort -n | head -1)

# C. تحليل PSNR
PSNR_Y=$(grep -oP 'y:\K[0-9.]+' "$PSNR_LOG" | awk '{ total += $1; count++ } END { print total/count }')

# D. التفسير اللفظي (Interpretation)
rating_vmaf() {
    val=$(printf "%.0f" "$1")
    if [ "$val" -ge 95 ]; then echo "Excellent (Indistinguishable)";
    elif [ "$val" -ge 88 ]; then echo "Good (Acceptable for Streaming)";
    elif [ "$val" -ge 70 ]; then echo "Fair (Noticeable Artifacts)";
    else echo "Poor (Unusable)"; fi
}

RATING_TEXT=$(rating_vmaf "$VMAF_SCORE")

# --- 5. كتابة التقرير النهائي ---
{
    echo "####################################################################"
    echo "             DEEP QUALITY FORENSICS REPORT"
    echo "####################################################################"
    echo "Date: $(date)"
    echo "Reference: $(basename "$REF")"
    echo "Distorted: $(basename "$DIST")"
    echo "--------------------------------------------------------------------"
    echo "1. VMAF METRICS (Human Perception - The Gold Standard)"
    printf "   • Mean Score:      %0.2f / 100  --> [%s]\n" "$VMAF_SCORE" "$RATING_TEXT"
    printf "   • Minimum Score:   %0.2f / 100  (Worst moment in video)\n" "$VMAF_MIN"
    printf "   • Harmonic Mean:   %0.2f / 100  (Overall stability)\n" "$VMAF_1_PERCENTILE"
    echo ""
    echo "   * Insight: If Min Score is < 70 while Mean is > 90, you have"
    echo "     'pulsing' quality issues (GOP alignment or bitrate spikes)."
    echo "--------------------------------------------------------------------"
    echo "2. SSIM METRICS (Structural Integrity - Text & Lines)"
    printf "   • Mean Y-SSIM:     %0.4f / 1.0000\n" "$SSIM_Y"
    printf "   • Min Y-SSIM:      %0.4f / 1.0000\n" "$SSIM_MIN"
    echo ""
    echo "   * Insight: For screencasts/text, aim for > 0.9600."
    echo "--------------------------------------------------------------------"
    echo "3. PSNR METRICS (Signal Engineering)"
    printf "   • Mean Y-PSNR:     %0.2f dB\n" "$PSNR_Y"
    echo "   * Insight: > 40dB is usually excellent for H.264."
    echo "####################################################################"
} > "$REPORT_FILE"

echo ">> [3/3] Report Generated: $REPORT_FILE"
# عرض التقرير فوراً
cat "$REPORT_FILE"