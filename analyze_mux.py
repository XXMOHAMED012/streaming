import os
import sys
import m3u8
import requests
import subprocess
import json
import shutil
from urllib.parse import urljoin
from tabulate import tabulate

# ==============================================================================
#  MUX FORENSIC ANALYZER (ROBUST VERSION)
# ==============================================================================

def get_ffprobe_data(file_path):
    """Deep analysis using ffprobe"""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        "-show_frames",
        "-select_streams", "v:0",  # Video only for frames
        "-read_intervals", "%+#100", # Read first 100 frames/packets only to be fast
        file_path
    ]
    # إضافة shell=False للأمان وتوافق أفضل
    result = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except Exception as e:
        # طباعة الخطأ إذا فشل ffprobe في إخراج JSON سليم
        # print(f"JSON Error: {e}") 
        return None

def analyze_gop(frames):
    """Analyze Group of Pictures structure with SAFE timestamp extraction"""
    if not frames:
        return "N/A", 0, 0
    
    i_frames = [f for f in frames if f.get('pict_type') == 'I']
    p_frames = [f for f in frames if f.get('pict_type') == 'P']
    b_frames = [f for f in frames if f.get('pict_type') == 'B']
    
    # دالة مساعدة لاستخراج التوقيت بأمان
    def get_ts(f):
        # 1. نحاول الحصول على PTS (وقت العرض)
        t = f.get('pkt_pts_time')
        # 2. إذا لم يوجد، نحاول الحصول على DTS (وقت فك التشفير)
        if not t:
            t = f.get('pkt_dts_time')
        # 3. تحويله لرقم أو إرجاع صفر
        try:
            return float(t) if t else 0.0
        except:
            return 0.0

    # حساب طول الـ GOP
    gop_len_sec = 0
    if len(i_frames) >= 2:
        # المسافة الزمنية بين أول إطارين I
        gop_len_sec = get_ts(i_frames[1]) - get_ts(i_frames[0])
    elif frames:
        # تقدير بناء على مدة العينة المحللة بالكامل إذا لم نجد I-Frames كافية
        gop_len_sec = get_ts(frames[-1]) - get_ts(frames[0])

    return f"I={len(i_frames)}, P={len(p_frames)}, B={len(b_frames)}", gop_len_sec, len(i_frames)

def download_file(url, folder, filename):
    local_path = os.path.join(folder, filename)
    try:
        # timeout مضاف لتجنب التعليق
        r = requests.get(url, stream=True, timeout=15)
        if r.status_code == 200:
            with open(local_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=1024):
                    f.write(chunk)
            return local_path
    except Exception as e:
        print(f"   ⚠️ Error downloading segment: {e}")
    return None

def main():
    if len(sys.argv) < 2:
        print("Usage: python analyze_mux.py <MUX_MASTER_URL>")
        sys.exit(1)

    master_url = sys.argv[1]
    work_dir = "mux_analysis_report"
    
    # Clean setup
    if os.path.exists(work_dir):
        shutil.rmtree(work_dir)
    os.makedirs(work_dir)

    print(f"🚀 Connecting to Mux: {master_url[:60]}...")
    
    # 1. Fetch Master
    try:
        master_playlist = m3u8.load(master_url)
    except Exception as e:
        print(f"❌ Failed to load master: {e}")
        sys.exit(1)

    # التحقق من وجود playlists
    if not master_playlist.playlists:
         print(f"⚠️ No variant playlists found. Is this a master m3u8?")
         # في بعض الأحيان قد يكون الرابط لملف ميديا مباشرة
         # يمكن إضافة معالجة هنا لكن لنفترض أنه ماستر سليم
         sys.exit(1)

    print(f"✅ Master loaded. Found {len(master_playlist.playlists)} quality variants.")

    report_data = []

    # 2. Iterate Variants
    for i, playlist in enumerate(master_playlist.playlists):
        variant_info = playlist.stream_info
        
        # استخراج الأبعاد والبيانات بأمان
        res = "N/A"
        if variant_info.resolution:
             res = f"{variant_info.resolution[0]}x{variant_info.resolution[1]}"
        
        bw = variant_info.bandwidth
        
        print(f"\n--- Analyzing Variant {i+1}: {res} ({bw} bps) ---")
        
        # Resolve Variant URL (Handle Relative Paths)
        variant_url = playlist.uri
        if not variant_url.startswith('http'):
            variant_url = urljoin(master_url, variant_url)

        # Download Variant Playlist
        try:
            var_m3u8_obj = m3u8.load(variant_url)
        except:
            print(f"   ❌ Failed to load variant playlist.")
            continue
        
        # Analyze first few segments
        segments_to_check = var_m3u8_obj.segments[:12] # First 3 is enough for pattern
        
        for seg_idx, seg in enumerate(segments_to_check):
            seg_url = seg.uri
            if not seg_url.startswith('http'):
                seg_url = urljoin(variant_url, seg_url)
            
            fname = f"{res}_{seg_idx}.ts"
            print(f"   Downloading Segment {seg_idx} ...", end="\r")
            local_ts = download_file(seg_url, work_dir, fname)
            
            if local_ts:
                # Run Forensics
                data = get_ffprobe_data(local_ts)
                if data:
                    # Extract Metrics
                    fmt = data.get('format', {})
                    streams = data.get('streams', [])
                    v_stream = next((s for s in streams if s['codec_type'] == 'video'), None)
                    
                    if v_stream:
                        duration = float(fmt.get('duration', 0))
                        size_kb = int(fmt.get('size', 0)) / 1024
                        real_bitrate = int(fmt.get('bit_rate', 0)) / 1000
                        codec = v_stream.get('codec_name', 'unknown')
                        profile = v_stream.get('profile', 'N/A')
                        level = v_stream.get('level', 'N/A')
                        
                        # GOP Analysis
                        gop_struct, gop_time, i_count = analyze_gop(data.get('frames', []))
                        
                        # Keyframe Check (Does it start with I frame?)
                        first_frame_type = '?'
                        if data.get('frames') and len(data['frames']) > 0:
                            first_frame_type = data['frames'][0].get('pict_type', '?')
                        
                        is_independent = "YES" if first_frame_type == 'I' else "NO"

                        report_data.append([
                            res, 
                            f"Seg {seg_idx}",
                            f"{duration:.2f}s",
                            f"{size_kb:.1f} KB",
                            f"{real_bitrate:.0f} k",
                            f"{profile} {level}",
                            gop_struct,
                            f"{gop_time:.2f}s",
                            is_independent
                        ])
            print(f"   ✅ Analyzed Segment {seg_idx}          ")

    # 3. Final Report
    print("\n\n" + "="*100)
    print("                              MUX FORENSIC REPORT")
    print("="*100)
    headers = ["Res", "Seg", "Dur", "Size", "Bitrate", "Profile", "GOP (I/P/B)", "GOP Dur", "Starts with I?"]
    print(tabulate(report_data, headers=headers, tablefmt="grid"))
    print("\nANALYSIS TIPS:")
    print("1. GOP Dur: If close to 6.00s, switch your SEG_TIME to 6.")
    print("2. Bitrate: Compare Mux's REAL bitrate with your TARGET bitrate.")
    print("3. B-Frames: If Mux has many B-frames (e.g. I=1, P=XX, B=XX), ensure you don't disable them.")
    print("="*100)

if __name__ == "__main__":
    main()