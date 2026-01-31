import os
import sys
import m3u8
import requests
import subprocess
import json
import shutil
import glob
from urllib.parse import urljoin
from tabulate import tabulate

# ==============================================================================
#  THE JUDGE: VMAF & SSIM COMPARATOR
# ==============================================================================

class QualityJudge:
    def __init__(self, original_file, work_dir="quality_lab"):
        self.original_file = original_file
        self.work_dir = work_dir
        if os.path.exists(work_dir):
            shutil.rmtree(work_dir)
        os.makedirs(work_dir)

    def download_segments(self, playlist_url, label, limit=10):
        """Downloads first N segments from a playlist"""
        print(f"   ⬇️ Downloading {label} segments...")
        folder = os.path.join(self.work_dir, label)
        os.makedirs(folder, exist_ok=True)
        
        try:
            if playlist_url.startswith("http"):
                m3u8_obj = m3u8.load(playlist_url)
                base_uri = playlist_url
            else:
                # Local file handling
                m3u8_obj = m3u8.load(playlist_url)
                base_uri = playlist_url

            segments = m3u8_obj.segments[:limit]
            ts_files = []

            for i, seg in enumerate(segments):
                seg_uri = seg.uri
                # Handle relative paths
                if not seg_uri.startswith("http") and not os.path.isabs(seg_uri):
                    if playlist_url.startswith("http"):
                        seg_uri = urljoin(base_uri, seg_uri)
                    else:
                        seg_uri = os.path.join(os.path.dirname(playlist_url), seg_uri)
                
                local_path = os.path.join(folder, f"seg_{i:03d}.ts")
                
                if seg_uri.startswith("http"):
                    r = requests.get(seg_uri, stream=True)
                    with open(local_path, 'wb') as f:
                        for chunk in r.iter_content(chunk_size=1024):
                            f.write(chunk)
                else:
                    shutil.copy(seg_uri, local_path)
                
                ts_files.append(local_path)
            
            return ts_files
        except Exception as e:
            print(f"   ❌ Error fetching segments for {label}: {e}")
            return []

    def concat_segments(self, ts_files, output_name):
        """Merges segments into one TS file for stable VMAF testing"""
        if not ts_files:
            return None
        
        list_file = os.path.join(self.work_dir, f"{output_name}_list.txt")
        with open(list_file, 'w') as f:
            for ts in ts_files:
                f.write(f"file '{os.path.abspath(ts)}'\n")
        
        merged_path = os.path.join(self.work_dir, f"{output_name}_merged.ts")
        
        # Concat using ffmpeg to fix timestamps
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-f", "concat", "-safe", "0",
            "-i", list_file,
            "-c", "copy",
            merged_path
        ]
        subprocess.run(cmd)
        return merged_path

    def get_duration(self, file_path):
        cmd = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", file_path]
        try:
            return float(subprocess.check_output(cmd).strip())
        except:
            return 0

    def prepare_reference(self, duration_sec, output_name):
        """Cuts the original file to match the segment duration exactly"""
        ref_path = os.path.join(self.work_dir, f"{output_name}_ref.mp4")
        
        # We assume segments start at 0.0
        # Important: re-encode to raw YUV or losslessly to avoid seeking keyframe issues during VMAF
        # But for speed, we try fast trim first. If VMAF fails, we decode.
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-i", self.original_file,
            "-t", str(duration_sec),
            "-c:v", "libx264", "-crf", "0", "-preset", "ultrafast", # Near lossless intermediate
            "-an", # No audio needed for VMAF
            ref_path
        ]
        subprocess.run(cmd)
        return ref_path

    def run_vmaf_ssim(self, distorted_path, reference_path):
        """
        Runs the VMAF and SSIM comparison.
        Scales distorted video to match reference if needed.
        """
        print(f"   🧪 Running VMAF/SSIM analysis (This takes time)...")
        
        log_path = distorted_path + "_vmaf.json"
        
        # Complex Filter:
        # 1. [0:v] (Distorted) -> Scale to 1920x1080 (assuming Ref is 1080p) -> setpts (sync)
        # 2. [1:v] (Reference) -> setpts (sync)
        # 3. Compare
        
        # Note: We assume Original is 1080p. If different, we should check ref width.
        # But usually we scale Distorted to match Reference.
        
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-i", distorted_path,
            "-i", reference_path,
            "-filter_complex", 
            "[0:v]scale=1920:1080:flags=bicubic,setpts=PTS-STARTPTS[dist];[1:v]setpts=PTS-STARTPTS[ref];[dist][ref]libvmaf=log_path={}:log_fmt=json:n_threads=4:feature=name=psnr".format(log_path) + ";[dist][ref]ssim",
            "-f", "null", "-"
        ]
        
        # Capture SSIM from stderr (ffmpeg outputs stats there)
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        # Parse SSIM from stderr
        ssim_score = 0.0
        for line in result.stderr.split('\n'):
            if "SSIM All" in line:
                # Format: SSIM All:0.98123...
                parts = line.split("All:")
                if len(parts) > 1:
                    ssim_score = float(parts[1].split()[0])
        
        # Parse VMAF from JSON
        vmaf_score = 0.0
        try:
            with open(log_path, 'r') as f:
                data = json.load(f)
                vmaf_score = data['pooled_metrics']['vmaf']['mean']
        except:
            print("   ⚠️ Could not read VMAF log.")
        
        return vmaf_score, ssim_score

    def get_master_variants(self, master_path):
        """Extracts resolution:url pairs from a master playlist"""
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

# ==============================================================================
#  MAIN EXECUTION
# ==============================================================================

def main():
    if len(sys.argv) < 4:
        print("Usage: python quality_judge.py <ORIGINAL.mp4> <MUX_MASTER_URL> <LOCAL_MASTER_PATH/URL>")
        sys.exit(1)

    orig_file = sys.argv[1]
    mux_master = sys.argv[2]
    local_master = sys.argv[3]
    
    judge = QualityJudge(orig_file)
    
    print("🔍 Parsing Playlists...")
    mux_variants = judge.get_master_variants(mux_master)
    local_variants = judge.get_master_variants(local_master)
    
    # Identify common resolutions to compare
    common_res = set(mux_variants.keys()).intersection(set(local_variants.keys()))
    
    if not common_res:
        print("❌ No common resolutions found between Mux and Local!")
        print(f"Mux: {list(mux_variants.keys())}")
        print(f"Local: {list(local_variants.keys())}")
        sys.exit(1)
        
    results_table = []
    
    for res in sorted(common_res, reverse=True): # Start high quality
        print(f"\n⚔️  BATTLE ROUND: {res} ⚔️")
        
        # 1. Process Mux
        mux_ts_files = judge.download_segments(mux_variants[res], f"mux_{res}", limit=10)
        mux_merged = judge.concat_segments(mux_ts_files, f"mux_{res}")
        
        # 2. Process Local
        local_ts_files = judge.download_segments(local_variants[res], f"local_{res}", limit=10)
        local_merged = judge.concat_segments(local_ts_files, f"local_{res}")
        
        if not mux_merged or not local_merged:
            print("   ⚠️ Skipping due to missing segments.")
            continue
            
        # 3. Prepare Reference (using Mux duration as baseline, usually they are similar)
        duration = judge.get_duration(mux_merged)
        reference = judge.prepare_reference(duration, f"ref_{res}")
        
        # 4. Fight!
        print(f"   🥊 Assessing Mux Quality...")
        mux_vmaf, mux_ssim = judge.run_vmaf_ssim(mux_merged, reference)
        
        print(f"   🥊 Assessing Local Quality...")
        loc_vmaf, loc_ssim = judge.run_vmaf_ssim(local_merged, reference)
        
        # Determine Winner
        diff = loc_vmaf - mux_vmaf
        if diff > 1: winner = "LOCAL 🏆"
        elif diff < -1: winner = "MUX 👑"
        else: winner = "DRAW 🤝"
        
        results_table.append([
            res, 
            f"{mux_vmaf:.2f}", f"{mux_ssim:.4f}",
            f"{loc_vmaf:.2f}", f"{loc_ssim:.4f}",
            winner
        ])
    
    print("\n\n" + "="*80)
    print("                      FINAL QUALITY VERDICT")
    print("="*80)
    headers = ["Resolution", "Mux VMAF", "Mux SSIM", "Local VMAF", "Local SSIM", "Winner"]
    print(tabulate(results_table, headers=headers, tablefmt="grid"))
    print("\nSCORE GUIDE:")
    print("* VMAF (0-100): 100 is identical to source. >93 is excellent. >80 is good.")
    print("* SSIM (0-1): 1.0 is identical. >0.95 is excellent.")
    print("="*80)

if __name__ == "__main__":
    main()