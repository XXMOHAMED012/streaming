# Production-Grade HLS Transcoding Engine Specification

## 1. Overview

This document outlines the architecture and logic for a robust, "Fast-Start" optimized VOD transcoding pipeline. The system is designed to convert raw uploaded videos into high-quality Adaptive Bitrate (ABR) HLS streams.

**Key Design Philosophies:**

- **Fast Start:** Optimized for sub-second playback startup using 4-second segments and precise Keyframe alignment.
- **Quality First:** Uses `Lanczos` scaling algorithm for sharp downscaling.
- **Memory Safe:** Optimized for containerized environments (Docker/Fly.io).
- **Smart Resolution:** Never upscales content (input-dependent ladder).
- **Forensic Reporting:** Generates detailed analytics (true bitrates, overhead).

---

## 2. Architecture & Workflow

The process follows a strict 4-stage pipeline:

1.  **Source Analysis:** Extract "DNA" of the input file.
2.  **Smart Ladder Construction:** Determine target resolutions based on input.
3.  **Transcoding Core:** Run FFmpeg for each quality with specific flags.
4.  **Forensics & Playlist Assembly:** Analyze output chunks and build the `master.m3u8`.

---

## 3. Step-by-Step Logic Implementation

### Phase 1: Source Analysis (Pre-flight)

Before processing, the system must extract metadata using `ffprobe`.

- **Required Metrics:**
  - `Duration` (seconds)
  - `FPS` (Frames Per Second) -> _Critical for GOP calculation._
  - `Width` & `Height`
  - `Bitrate` (Original)

### Phase 2: The "Smart Ladder" Logic

The system must **not** generate a quality level higher than the source.

- **Logic:**
  - If Source Height >= 1080p → Generate 1080p, 720p, 480p.
  - If Source Height >= 720p → Generate 720p, 480p.
  - Else → Generate 480p only.

- **Target Bitrates (VBR Recommendations):**
  - **1080p:** 4500k (Max: 7500k, Buf: 7500k)
  - **720p:** 2500k (Max: 4200k, Buf: 4200k)
  - **480p:** 800k (Max: 2000k, Buf: 2000k)
  - _CRF:_ 28 (Visual constant quality baseline).

### Phase 3: The Encoding Core (FFmpeg Configuration)

This is the most critical section. The FFmpeg command must match these specifications exactly.

**Global Calculations:**

- `SEGMENT_TIME` = **4 seconds**
- `GOP_SIZE` = `FPS * SEGMENT_TIME` (Exact alignment)

**FFmpeg Flags Breakdown:**

| Category         | Flag                    | Value / Logic                         | Reason                                                                      |
| :--------------- | :---------------------- | :------------------------------------ | :-------------------------------------------------------------------------- |
| **Scaling**      | `-vf`                   | `scale=w=${WIDTH}:h=-2:flags=lanczos` | `lanczos` provides the sharpest image for downscaling.                      |
| **Codec**        | `-c:v`                  | `libx264`                             | Profile: `high`, Preset: `veryslow`, Tune: `animation`.                     |
| **Rate Control** | `-b:v`                  | Target Bitrate                        | Limits average bandwidth usage.                                             |
| **Buffering**    | `-maxrate`, `-bufsize`  | Specified in Ladder                   | Prevents bitrate spikes that cause buffering.                               |
| **Alignment**    | `-g`, `-keyint_min`     | `GOP_SIZE`                            | Forces a GOP structure exactly matching segment duration.                   |
| **Fast Start**   | `-force_key_frames`     | `expr:gte(t,n_forced*4)`              | **Crucial:** Forces an IDR frame exactly at the start of every segment.     |
| **Stability**    | `-flags`                | `+cgop`                               | (Closed GOP) Makes segments independent (no artifacting on quality switch). |
| **HLS Format**   | `-hls_time`             | `4`                                   | Small segments for fast seek/start.                                         |
| **Container**    | `-hls_segment_type`     | `mpegts`                              | Classic TS format for max compatibility.                                    |
| **Structure**    | `-hls_segment_filename` | `{VARIANT_DIR}/seg_%03d.ts`           | Output segments into specific quality folders.                              |

### Phase 4: Forensics & Analysis (Post-Processing)

After generating segments for a quality level, the system must analyze the output to generate the report and the master playlist.

**1. Bandwidth Calculation:**

- **Average Bitrate:** `(Total Folder Size * 8) / Duration`
- **Peak Bitrate:** Find the largest `.ts` file → `(File Size * 8) / 4 seconds`.

**2. Overhead Estimation:**

- MPEG-TS Overhead is approx **8%** of total size.

---

## 3. Directory Structure

The backend must organize the output S3/Local folder as follows:

```text
/video-id-folder/
├── master.m3u8              (Root Manifest)
├── REPORT_MASTER.txt        (Detailed Analytics)
├── 1080p/
│   ├── index.m3u8           (Variant Manifest)
│   ├── seg_001.ts
│   ├── seg_002.ts
│   └── ...
├── 720p/
│   ├── index.m3u8
│   └── ...
└── 480p/
    ├── index.m3u8
    └── ...
```

---

## 4. Master Playlist Generation

The `master.m3u8` must be constructed with calculated values to ensure player stability.

**Rules:**

1. **Header:** `#EXTM3U`, `#EXT-X-VERSION:3`, `#EXT-X-INDEPENDENT-SEGMENTS`.
2. **Ordering:** Place higher quality first
3. **Entry Format:**

```m3u8
#EXT-X-STREAM-INF:BANDWIDTH={PEAK_BW},AVERAGE-BANDWIDTH={AVG_BW},RESOLUTION={WxH},CODECS="avc1.640028,mp4a.40.2"
{QUALITY_NAME}/index.m3u8
```

---

## 5. Reporting Metrics (JSON/Text)

The system should log the following for each quality level:

1. **Encoding Time:** Seconds taken.
1. **Total Size:** Total size in MB.
1. **Speed Factor:** (Source Duration / Encoding Time).
1. **Compression Ratio:** (Source Size / Output Size).
1. **True Bitrate:** Actual Avg vs Target.
1. **Reduction %:** How much space was saved.
1. **Overhead:** TS container overhead cost.

---

## 6. Implementation Notes for Node.js/Backend

If implementing this in a Node.js Worker:

1. **Do not use** `fluent-ffmpeg` for the complex command construction if it limits flag flexibility. Using `child_process.spawn` with a raw argument array is often safer for this level of customization.
2. **Concurrency:** Ensure the worker processes only **one video at a time** per CPU core to avoid OOM (Out Of Memory) kills.
3. **Volume Usage:** Check if a persistent volume (e.g., `/data`) exists. Use it for the `temp` directory to avoid filling the root filesystem.
4. **Cleanup:** Aggressively delete the `temp` folder after upload to S3.

```

```
