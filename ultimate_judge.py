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
#  THE ULTIMATE JUDGE V2: PERFECT SYNC + EFFICIENCY SCORE
# ==============================================================================

class UltimateAnalyzer:
    def __init__(self, original_file, work_dir="ultimate_lab_v2"):
        self.original_file = original_file
        self.work_dir = work_dir
        if os.path.exists(work_dir):
            shutil.rmtree(work_dir)
        os.makedirs(work_dir)

    # --- DOWNLOAD MANAGER ---
    def get_master_variants(self, master_path):
        variants = {}
        try:
            m = m3u8.load(master_path)
            for p in m.playlists:
                res = "N/A"
                if p.stream_info.resolution:
                    res = f"{p.stream_info.resolution[0]}x{p.stream_info.resolution[1]}"
                
                uri = p.uri
                if not uri.startswith("http") and master_path.startswith("http"):
                    uri = urljoin(master_path, uri)
                elif not os.path.isabs(uri) and not master_path.startswith("http"):
                     uri = os.path.join(os.path.dirname(master_path), uri)
                variants[res] = uri
        except Exception as e:
            print(f"Error reading master {master_path}: {e}")
        return variants

    def download_segments(self, playlist_url, label, limit=10):
        folder = os.path.join(self.work_dir, label)
        os.makedirs(folder, exist_ok=True)
        try:
            m3u8_obj = m3u8.load(playlist_url)
            base_uri = playlist_url
            segments = m3u8_obj.segments[:limit]
            ts_files = []
            
            def resolve(uri):
                if uri.startswith("http"): return uri
                if playlist_url.startswith("http"): return urljoin(base_uri, uri)
                return os.path.join(os.path.dirname(playlist_url), uri)

            print(f"   ⬇️  Fetching {len(segments)} segments for {label}...", end="\r")
            for i, seg in enumerate(segments):
                local_path = os.path.join(folder, f"seg_{i:03d}.ts")
                seg_uri = resolve(seg.uri)
                
                if seg_uri.startswith("http"):
                    try:
                        r = requests.get(seg_uri, stream=True, timeout=15)
                        if r.status_code == 200:
                            with open(local_path, 'wb') as f:
                                for chunk in r.iter_content(chunk_size=1024): f.write(chunk)
                            ts_files.append(local_path)
                    except: pass
                else:
                    if os.path.exists(seg_uri):
                        shutil.copy(seg_uri, local_path)
                        ts_files.append(local_path)
            print(f"   ✅ Fetched {len(ts_files)} segments for {label}          ")
            return ts_files
        except Exception as e:
            print(f"   ❌ Error fetching {label}: {e}")
            return []

    # --- PROCESSING ---
    def concat_and_trim(self, ts_files, output_name, duration=None):
        if not ts_files: return None
        
        # 1. Concat
        list_file = os.path.join(self.work_dir, f"{output_name}_list.txt")
        with open(list_file, 'w') as f:
            for ts in ts_files: f.write(f"file '{os.path.abspath(ts)}'\n")
        
        merged_path = os.path.join(self.work_dir, f"{output_name}_merged.ts")
        # Added -safe 0 and loglevel error
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list_file, "-c", "copy", merged_path])
        
        # 2. Trim (Force Exact Duration)
        final_path = merged_path
        if duration:
            trimmed_path = os.path.join(self.work_dir, f"{output_name}_final.ts")
            # Re-encoding usually safer for precise trim, but copy is okay if keyframes align (which they should now)
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", merged_path, "-t", str(duration), "-c", "copy", trimmed_path])
            final_path = trimmed_path
            
        return final_path

    def get_duration(self, file_path):
        try:
            cmd = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", file_path]
            return float(subprocess.check_output(cmd).strip())
        except: return 0

    def prepare_reference(self, duration_sec):
        ref_path = os.path.join(self.work_dir, "reference_cut.mp4")
        # Cut original exactly
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-i", self.original_file,
            "-t", str(duration_sec),
            "-c:v", "libx264", "-crf", "0", "-preset", "ultrafast", "-an",
            ref_path
        ]
        subprocess.run(cmd)
        return ref_path

    # --- FORENSICS (Fixed GOP Logic) ---
    def get_forensics(self, file_path_for_metrics, file_path_for_gop):
        """
        file_path_for_metrics: The Full merged file (for bitrate/size)
        file_path_for_gop: The FIRST individual segment (for accurate GOP/Profile)
        """
        # 1. Get Bitrate/Size from Merged
        cmd_metrics = ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", file_path_for_metrics]
        res_metrics = subprocess.run(cmd_metrics, capture_output=True, text=True)
        data_metrics = json.loads(res_metrics.stdout)
        fmt = data_metrics['format']
        size_mb = float(fmt['size']) / 1024 / 1024
        bitrate_kbps = int(float(fmt['bit_rate'])) / 1000 if 'bit_rate' in fmt else 0

        # 2. Get GOP/Profile from First Segment
        cmd_gop = [
            "ffprobe", "-v", "quiet", "-print_format", "json",
            "-show_streams", "-show_frames",
            "-select_streams", "v:0", 
            "-read_intervals", "%+#50", # Read first 50 frames
            file_path_for_gop
        ]
        res_gop = subprocess.run(cmd_gop, capture_output=True, text=True)
        data_gop = json.loads(res_gop.stdout)
        stream = next((s for s in data_gop['streams'] if s['codec_type'] == 'video'), {})
        frames = data_gop.get('frames', [])
        
        profile = stream.get('profile', 'N/A')
        
        i_frames = [f for f in frames if f.get('pict_type') == 'I']
        p_frames = [f for f in frames if f.get('pict_type') == 'P']
        b_frames = [f for f in frames if f.get('pict_type') == 'B']
        
        gop_dur = 0
        if len(i_frames) >= 2:
            def get_ts(f): return float(f.get('pkt_pts_time') or f.get('pkt_dts_time') or 0)
            gop_dur = get_ts(i_frames[1]) - get_ts(i_frames[0])
        elif len(i_frames) == 1 and frames:
             # Estimate if only 1 I-frame in sample
             def get_ts(f): return float(f.get('pkt_pts_time') or f.get('pkt_dts_time') or 0)
             gop_dur = get_ts(frames[-1]) - get_ts(frames[0])

        return {
            "size_mb": size_mb,
            "bitrate": bitrate_kbps,
            "profile": profile,
            "gop_str": f"I={len(i_frames)},P={len(p_frames)},B={len(b_frames)}",
            "gop_dur": gop_dur
        }

    # --- QUALITY (VMAF) ---
    def calc_vmaf(self, distorted, reference):
        print(f"   🧪 Running VMAF Calculation...", end="\r")
        log_path = distorted + "_vmaf.json"
        
        # Scale distorted to match reference
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-i", distorted, "-i", reference,
            "-filter_complex", 
            "[0:v]scale=1920:1080:flags=bicubic[dist];[dist][1:v]libvmaf=log_path={}:log_fmt=json:n_threads=4".format(log_path),
            "-f", "null", "-"
        ]
        subprocess.run(cmd)
        
        try:
            with open(log_path, 'r') as f:
                data = json.load(f)
                score = data['pooled_metrics']['vmaf']['mean']
                print(f"   🧪 VMAF Complete: {score:.2f}          ")
                return score
        except: 
            print("   ⚠️ VMAF Failed")
            return 0.0

# ==============================================================================
#  MAIN EXECUTION
# ==============================================================================

def main():
    if len(sys.argv) < 4:
        print("Usage: python ultimate_judge_v2.py <ORIGINAL.mp4> <MUX_MASTER> <LOCAL_MASTER>")
        sys.exit(1)

    analyzer = UltimateAnalyzer(sys.argv[1])
    
    print("🔍 Parsing Playlists...")
    mux_vars = analyzer.get_master_variants(sys.argv[2])
    loc_vars = analyzer.get_master_variants(sys.argv[3])
    
    common_res = set(mux_vars.keys()).intersection(set(loc_vars.keys()))
    if not common_res:
        print("❌ No common resolutions found!")
        sys.exit(1)

    table_data = []

    for res in sorted(common_res, reverse=True):
        print(f"\n⚙️  PROCESSING RESOLUTION: {res} ⚙️")
        
        # 1. Download
        # Download 12 segments (12*5 = 60s) for both since now SEG_TIME matches!
        mux_ts = analyzer.download_segments(mux_vars[res], f"mux_{res}", limit=12)
        loc_ts = analyzer.download_segments(loc_vars[res], f"loc_{res}", limit=12)
        
        if not mux_ts or not loc_ts: continue

        # 2. Merge
        mux_full = analyzer.concat_and_trim(mux_ts, f"mux_{res}")
        loc_full = analyzer.concat_and_trim(loc_ts, f"loc_{res}")

        # 3. Time Normalize
        d_mux = analyzer.get_duration(mux_full)
        d_loc = analyzer.get_duration(loc_full)
        common_dur = min(d_mux, d_loc)
        print(f"   ⏱️  Test Duration: {common_dur:.2f} sec")

        # 4. Final Trim
        mux_final = analyzer.concat_and_trim([mux_full], f"mux_{res}_final", common_dur)
        loc_final = analyzer.concat_and_trim([loc_full], f"loc_{res}_final", common_dur)
        ref_final = analyzer.prepare_reference(common_dur)

        # 5. FORENSICS (Use First Segment for GOP accuracy)
        f_mux = analyzer.get_forensics(mux_final, mux_ts[0])
        f_loc = analyzer.get_forensics(loc_final, loc_ts[0])

        # 6. QUALITY
        vmaf_mux = analyzer.calc_vmaf(mux_final, ref_final)
        vmaf_loc = analyzer.calc_vmaf(loc_final, ref_final)

        # 7. EFFICIENCY SCORE (VMAF per MB)
        # How much quality do I get for 1 MB of data? Higher is better engineering.
        eff_mux = vmaf_mux / f_mux['size_mb'] if f_mux['size_mb'] > 0 else 0
        eff_loc = vmaf_loc / f_loc['size_mb'] if f_loc['size_mb'] > 0 else 0

        # Verdict Logic
        vmaf_diff = vmaf_loc - vmaf_mux
        
        if vmaf_diff > 0.5: 
            verdict = "LOCAL Wins (Quality) 🏆"
        elif vmaf_diff < -0.5: 
            if eff_loc > eff_mux: verdict = "MUX Quality / LOCAL Efficiency ⚖️"
            else: verdict = "MUX Wins 👑"
        else: 
            if eff_loc > eff_mux: verdict = "TIE (LOCAL More Efficient) 🚀"
            else: verdict = "TIE 🤝"

        table_data.append([
            res,
            f"{f_mux['bitrate']:.0f} / {f_loc['bitrate']:.0f} k",
            f"{f_mux['size_mb']:.1f} / {f_loc['size_mb']:.1f} MB",
            f"{f_mux['gop_dur']:.1f} / {f_loc['gop_dur']:.1f} s",
            f"{vmaf_mux:.1f} / {vmaf_loc:.1f}",
            f"{eff_mux:.1f} / {eff_loc:.1f}",
            verdict
        ])

    print("\n\n" + "="*110)
    print("                              THE ULTIMATE COMPARISON REPORT (V2)")
    print("                              Format: (Mux Value / Local Value)")
    print("="*110)
    
    headers = ["Res", "Bitrate", "Size", "GOP Dur", "VMAF Score", "Efficiency (VMAF/MB)", "Verdict"]
    print(tabulate(table_data, headers=headers, tablefmt="grid"))
    print("\nMETRICS GUIDE:")
    print("* VMAF Score: Higher is better visual quality (Max 100).")
    print("* Efficiency: Quality per Megabyte. Higher means smarter compression.")
    print("* GOP Dur: Must be identical (e.g., 5.0 / 5.0).")
    print("="*110)

if __name__ == "__main__":
    main()