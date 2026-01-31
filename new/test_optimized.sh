#!/bin/bash

# Exit on any error
set -e

# Simple Fly.io Performance Test (E-Learning Optimized)
# Uses taskset to limit CPU cores

echo "╔════════════════════════════════════════════════════════════╗"
echo "║      E-Learning Optimization Performance Test              ║"
echo "║   (Optimized for Slides, Screencasts & Text Clarity)       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check dependencies
check_dependency() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ Required command not found: $1"
        echo "   Install it with: sudo apt install $2"
        exit 1
    fi
}

check_dependency "ffmpeg" "ffmpeg"
check_dependency "ffprobe" "ffmpeg"
check_dependency "bc" "bc"

# Check GPU availability and NVENC support
GPU_AVAILABLE=0
NVENC_AVAILABLE=0

if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        GPU_AVAILABLE=1
        echo "✓ NVIDIA GPU detected"
        
        # Check if FFmpeg has NVENC support
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
            # Try a quick NVENC test
            if ffmpeg -f lavfi -i nullsrc=s=256x256:d=0.1 -c:v h264_nvenc -f null - >/dev/null 2>&1; then
                NVENC_AVAILABLE=1
                echo "✓ NVENC hardware encoding available"
            else
                echo "⚠️  GPU detected but NVENC encoding failed"
                echo "   GPU tests will be skipped."
            fi
        else
            echo "⚠️  GPU detected but FFmpeg lacks NVENC support"
            echo "   GPU tests will be skipped."
        fi
    fi
fi
echo ""

# Config - Fixed at 1080p for testing
SCALE_WIDTH=1920
echo "✓ Target resolution: 1080p (${SCALE_WIDTH}x1080)"
echo ""

# Ask for input file
echo "Input video file:"
echo "  1) Use existing file (provide path)"
echo "  2) Create test video (90 seconds, 1080p, simulated slides)"
echo ""
read -p "Choose option [1-2]: " input_choice

case $input_choice in
    1)
        read -p "Enter path to video file: " INPUT
        if [ ! -f "$INPUT" ]; then
            echo "❌ File not found: $INPUT"
            exit 1
        fi
        
        # Get video duration for cost calculation
        echo "📊 Analyzing video..."
        if ! DURATION_SEC=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null); then
            echo "❌ Failed to read video duration"
            exit 1
        fi
        
        if [ -z "$DURATION_SEC" ] || [ "$DURATION_SEC" = "N/A" ]; then
            echo "❌ Could not determine video duration"
            exit 1
        fi
        
        DURATION_MIN=$(echo "$DURATION_SEC / 60" | bc -l)
        printf "✓ Video loaded: %s (%.1f minutes)\n\n" "$INPUT" "$DURATION_MIN"
        ;;
    2)
        INPUT="test_input.mp4"
        if [ ! -f "$INPUT" ]; then
            echo "📹 Creating 90-second simulated slide content..."
            # Create content with text and lower framerate (more representative of screen recording)
            if ! ffmpeg -f lavfi -i "testsrc=duration=90:size=1920x1080:rate=30" \
                -vf "drawtext=text='E-Learning Test':fontsize=60:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
                -pix_fmt yuv420p \
                -c:v libx264 -preset medium -crf 23 "$INPUT" -y 2>/dev/null; then
                echo "❌ Failed to create test video"
                exit 1
            fi
            echo "✓ Test video created"
        else
            echo "✓ Using existing test video: $INPUT"
        fi
        DURATION_SEC=90
        DURATION_MIN=1.5
        echo ""
        ;;
    *)
        echo "❌ Invalid choice"
        exit 1
        ;;
esac

# Test configurations matching Fly.io
declare -A CONFIGS
CONFIGS=(
    ["Your Current (perf-4x- slow preset)"]="4:slow:libx264"
    ["Performance-2x (2 CPU- veryfast)"]="2:veryfast:libx264"
    ["Performance-4x (4 CPU- veryfast)"]="4:veryfast:libx264"
    ["Performance-8x (8 CPU- veryfast)"]="8:veryfast:libx264"
)

# Add GPU tests only if NVENC is actually working
if [ $NVENC_AVAILABLE -eq 1 ]; then
    CONFIGS["GPU (NVENC p4 preset)"]="all:p4:nvenc"
fi

echo "Available tests:"
i=1
for name in "${!CONFIGS[@]}"; do
    echo "  $i) $name"
    ((i++))
done
echo ""
read -p "Select test to run (or 'all'): " choice

# Function to monitor RAM usage
monitor_ram() {
    local pid=$1
    local output_file=$2
    local max_ram=0
    
    while kill -0 $pid 2>/dev/null; do
        # Get RSS (Resident Set Size) in KB for the process and all children
        local current_ram=$(ps -o rss= -p $pid --ppid $pid 2>/dev/null | awk '{sum+=$1} END {print sum}')
        if [ -n "$current_ram" ] && [ "$current_ram" -gt "$max_ram" ]; then
            max_ram=$current_ram
        fi
        sleep 0.5
    done
    
    # Convert KB to MB
    echo "scale=2; $max_ram / 1024" | bc > "$output_file"
}

run_single_test() {
    local name=$1
    local config=${CONFIGS[$name]}
    IFS=':' read -r cpus preset encoder <<< "$config"
    
    # Sanitize output directory name (remove special characters)
    local output="output_${name// /_}"
    output="${output//(/}"
    output="${output//)/}"
    output="${output//,/}"
    mkdir -p "$output"
    
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "Test: $name"
    echo "════════════════════════════════════════════════════════════"
    
    # Build command
    local cmd=""
    local taskset=""
    
    if [ "$cpus" != "all" ]; then
        taskset="taskset -c 0-$((cpus-1))"
        echo "🔧 Limited to $cpus CPU cores (0-$((cpus-1)))"
    fi
    
    # ------------------------------------------------------------------
    #  OPTIMIZATION EXPLANATION
    # ------------------------------------------------------------------
    # 1. Scale: Uses 'flags=lanczos' for sharper text resizing (critical for slides).
    # 2. Tune: Uses '-tune animation' (x264) for flat colors and sharp edges.
    # 3. Bitrate: Uses CRF 28 (Constant Rate Factor) instead of fixed bitrate. 
    #    E-learning content is simple; fixed bitrate wastes space. CRF allocates bits only when needed.
    # 4. GOP (-g): Increased to 240 (8 sec). Slides don't move; we don't need frequent refreshes.
    # 5. Scenecut: Enabled (default) to detect slide changes immediately.
    # ------------------------------------------------------------------

    if [ "$encoder" = "nvenc" ]; then
        # NVENC Configuration for E-learning
        # Uses -cq (Constant Quality) similar to CRF
        cmd="ffmpeg -y -hide_banner -loglevel error -stats \
            -hwaccel cuda -hwaccel_output_format cuda \
            -i \"$INPUT\" \
            -vf scale_cuda=w=${SCALE_WIDTH}:h=-2 \
            -c:v h264_nvenc -preset $preset \
            -rc:v vbr -cq 28 -b:v 0 -maxrate 1500k -bufsize 3000k \
            -g 240 -forced-idr 1 \
            -c:a aac -b:a 128k \
            -hls_time 10 -hls_playlist_type vod \
            -hls_segment_filename \"$output/video_%03d.ts\" \
            \"$output/video.m3u8\""
    else
        # CPU (x264) Configuration for E-learning
        cmd="ffmpeg -y -hide_banner -loglevel error -stats \
            -i \"$INPUT\" \
            -vf scale=w=${SCALE_WIDTH}:h=-2:flags=lanczos \
            -c:v libx264 -preset $preset -tune animation \
            -crf 28 -maxrate 1500k -bufsize 3000k \
            -g 240 -keyint_min 24 -sc_threshold 40 \
            -c:a aac -b:a 128k \
            -hls_time 10 -hls_playlist_type vod \
            -hls_segment_filename \"$output/video_%03d.ts\" \
            \"$output/video.m3u8\""
    fi
    
    # Build full command with taskset
    local full_cmd="$taskset $cmd"
    
    # Run test with RAM monitoring
    echo "⏱️  Encoding..."
    START=$(date +%s.%N)
    
    # Start FFmpeg in background
    eval "$full_cmd" &
    local ffmpeg_pid=$!
    
    # Monitor RAM usage in background
    local ram_file="/tmp/ram_usage_$$"
    monitor_ram $ffmpeg_pid "$ram_file" &
    local monitor_pid=$!
    
    # Wait for FFmpeg to complete
    if ! wait $ffmpeg_pid; then
        kill $monitor_pid 2>/dev/null || true
        rm -f "$ram_file"
        echo ""
        echo "❌ Encoding failed! Check the error above."
        exit 1
    fi
    
    # Wait for monitor to finish
    wait $monitor_pid 2>/dev/null || true
    
    END=$(date +%s.%N)
    
    # Get peak RAM usage
    local peak_ram="0"
    if [ -f "$ram_file" ]; then
        peak_ram=$(cat "$ram_file")
        rm -f "$ram_file"
    fi
    
    # Results
    DURATION=$(echo "$END - $START" | bc)
    SIZE=$(du -sh "$output" | cut -f1)
    
    echo ""
    echo "✓ Complete!"
    echo "  Time: ${DURATION}s"
    echo "  Peak RAM: ${peak_ram} MB"
    echo "  Size: $SIZE"
    echo "  Location: $output/"
    
    # Cost estimate based on actual input video duration
    case $name in
        *"2x"*) RATE=0.0861 ;;
        *"4x"*) RATE=0.1722 ;;
        *"8x"*) RATE=0.3444 ;;
        *"GPU"*) RATE=1.25 ;;
        *) RATE=0.1722 ;;
    esac
    
    # Calculate cost for encoding this specific video
    HOURS=$(echo "$DURATION / 3600" | bc -l)
    COST=$(echo "$HOURS * $RATE" | bc -l)
    
    # Extrapolate to 1 hour of video
    MULTIPLIER=$(echo "3600 / $DURATION_SEC" | bc -l)
    TIME_FOR_1HR=$(echo "$DURATION * $MULTIPLIER / 60" | bc -l)
    COST_FOR_1HR=$(echo "$COST * $MULTIPLIER" | bc -l)
    
    printf "\n💰 Cost estimate:\n"
    printf "   This video: \$%.4f (%.1f sec encoding)\n" "$COST" "$DURATION"
    printf "   1 hour of video: \$%.4f (%.1f min encoding)\n" "$COST_FOR_1HR" "$TIME_FOR_1HR"
    
    # Save result
    echo "$name,$DURATION,$peak_ram,$SIZE,$COST_FOR_1HR" >> test_results.csv
}

# Initialize results
echo "Configuration,Time(s),Peak RAM (MB),Size,Cost(1hr video)" > test_results.csv

if [ "$choice" = "all" ]; then
    for name in "${!CONFIGS[@]}"; do
        run_single_test "$name"
    done
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                  COMPARISON SUMMARY                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    column -t -s',' test_results.csv
else
    # Run single test
    i=1
    for name in "${!CONFIGS[@]}"; do
        if [ "$i" -eq "$choice" ]; then
            run_single_test "$name"
            break
        fi
        ((i++))
    done
fi

echo ""
echo "✓ Testing complete!"
echo "Results saved to: test_results.csv"
