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
#  THE ULTIMATE JUDGE: FORENSICS + VMAF
# ==============================================================================

class UltimateAnalyzer:
    def __init__(self, original_file, work_dir="ultimate_lab"):
        self.original_file = original_file
        self.work_dir = work_dir
        if os.path.exists(work_dir):
            shutil.rmtree(work_dir)
        os.makedirs(work_dir)

    # --- NETWORK & DOWNLOAD ---
    def get_master_variants(self, master_path):
        variants = {}
        try:
            m = m3u8.load(master_path)
            for p in m.playlists:
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

    def download_segments(self, playlist_url, label, limit=12):
        folder = os.path.join(self.work_dir, label)
        os.makedirs(folder, exist_ok=True)
        try:
            m3u8_obj = m3u8.load(playlist_url)
            base_uri = playlist_url
            segments = m3u8_obj.segments[:limit]
            ts_files = []
            
            # Helper to resolve URL
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
                        r = requests.get(seg_uri, stream=True, timeout=10)
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
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list_file, "-c", "copy", merged_path])
        
        # 2. Trim (if duration is set)
        final_path = merged_path
        if duration:
            trimmed_path = os.path.join(self.work_dir, f"{output_name}_final.ts")
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
        # Cut original file exactly to match test duration
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-i", self.original_file,
            "-t", str(duration_sec),
            "-c:v", "libx264", "-crf", "0", "-preset", "ultrafast", "-an",
            ref_path
        ]
        subprocess.run(cmd)
        return ref_path

    # --- FORENSICS ---
    def get_forensics(self, file_path):
        """Extracts technical details from the video file"""
        cmd = [
            "ffprobe", "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", "-show_frames",
            "-select_streams", "v:0", "-read_intervals", "%+#50", # Read first 50 frames for GOP
            file_path
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            data = json.loads(result.stdout)
            
            fmt = data['format']
            stream = next((s for s in data['streams'] if s['codec_type'] == 'video'), {})
            frames = data.get('frames', [])

            # Metrics
            size_mb = float(fmt['size']) / 1024 / 1024
            dur = float(fmt['duration'])
            bitrate_kbps = int(float(fmt['bit_rate'])) / 1000 if 'bit_rate' in fmt else 0
            profile = stream.get('profile', 'N/A')
            
            # GOP Analysis
            i_frames = [f for f in frames if f.get('pict_type') == 'I']
            p_frames = [f for f in frames if f.get('pict_type') == 'P']
            b_frames = [f for f in frames if f.get('pict_type') == 'B']
            
            gop_dur = 0
            if len(i_frames) >= 2:
                t1 = float(i_frames[0].get('pkt_pts_time', i_frames[0].get('pkt_dts_time')))
                t2 = float(i_frames[1].get('pkt_pts_time', i_frames[1].get('pkt_dts_time')))
                gop_dur = t2 - t1
            
            return {
                "size_mb": size_mb,
                "bitrate": bitrate_kbps,
                "profile": profile,
                "gop_str": f"I={len(i_frames)},P={len(p_frames)},B={len(b_frames)}",
                "gop_dur": gop_dur
            }
        except:
            return None

    # --- QUALITY (VMAF) ---
    def calc_vmaf(self, distorted, reference):
        print(f"   🧪 Running VMAF (Distorted vs Ref)...")
        log_path = distorted + "_vmaf.json"
        
        # Scale distorted to match reference (1920x1080 usually) to avoid VMAF errors
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
                return data['pooled_metrics']['vmaf']['mean']
        except: return 0.0

# ==============================================================================
#  MAIN EXECUTION
# ==============================================================================

def main():
    if len(sys.argv) < 4:
        print("Usage: python ultimate_judge.py <ORIGINAL.mp4> <MUX_MASTER> <LOCAL_MASTER>")
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
        
        # 1. Download (Fetch more Local segments to match Mux time)
        # Mux (5s GOP) -> 12 segments = 60s
        # Local (4s GOP) -> 15 segments = 60s
        mux_ts = analyzer.download_segments(mux_vars[res], f"mux_{res}", limit=12)
        loc_ts = analyzer.download_segments(loc_vars[res], f"loc_{res}", limit=15)
        
        if not mux_ts or not loc_ts: continue

        # 2. Merge Initial
        mux_full = analyzer.concat_and_trim(mux_ts, f"mux_{res}")
        loc_full = analyzer.concat_and_trim(loc_ts, f"loc_{res}")

        # 3. Time Normalization
        d_mux = analyzer.get_duration(mux_full)
        d_loc = analyzer.get_duration(loc_full)
        common_dur = min(d_mux, d_loc)
        print(f"   ⏱️  Normalizing Duration to: {common_dur:.2f} sec")

        # 4. Final Trim
        mux_final = analyzer.concat_and_trim([mux_full], f"mux_{res}_final", common_dur)
        loc_final = analyzer.concat_and_trim([loc_full], f"loc_{res}_final", common_dur)
        ref_final = analyzer.prepare_reference(common_dur)

        # 5. FORENSICS (Analyze the Final Trimmed Files)
        f_mux = analyzer.get_forensics(mux_final)
        f_loc = analyzer.get_forensics(loc_final)

        # 6. QUALITY (VMAF)
        vmaf_mux = analyzer.calc_vmaf(mux_final, ref_final)
        vmaf_loc = analyzer.calc_vmaf(loc_final, ref_final)

        # 7. Comparison Data
        # Format: Mux Value / Local Value
        
        # Calculate Delta
        vmaf_diff = vmaf_loc - vmaf_mux
        if vmaf_diff > 0.5: winner = "LOCAL 🏆"
        elif vmaf_diff < -0.5: winner = "MUX 👑"
        else: winner = "TIE 🤝"

        table_data.append([
            res,
            f"{f_mux['bitrate']:.0f} / {f_loc['bitrate']:.0f} k",
            f"{f_mux['size_mb']:.1f} / {f_loc['size_mb']:.1f} MB",
            f"{f_mux['profile']} / {f_loc['profile']}",
            f"{f_mux['gop_dur']:.1f}s / {f_loc['gop_dur']:.1f}s",
            f"{f_mux['gop_str']} \n {f_loc['gop_str']}", # Stacked for readability
            f"{vmaf_mux:.2f} / {vmaf_loc:.2f}",
            winner
        ])

    print("\n\n" + "="*100)
    print("                              THE ULTIMATE COMPARISON REPORT")
    print("                              Format: (Mux Value / Local Value)")
    print("="*100)
    
    headers = ["Res", "Bitrate (kbps)", "Size (MB)", "Profile", "GOP Dur", "GOP Struct (I,P,B)", "VMAF Score", "Verdict"]
    print(tabulate(table_data, headers=headers, tablefmt="grid"))
    print("\nNOTES:")
    print("- VMAF: Higher is better. >93 is excellent.")
    print("- GOP Dur: Should match SEG_TIME (Mux=5s, You=5s).")
    print("- GOP Struct: More 'B' frames = Better compression.")
    print("="*100)

if __name__ == "__main__":
    main()