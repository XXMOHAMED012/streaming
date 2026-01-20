import { Worker, Job } from "bullmq";
import IORedis from "ioredis";
import path from "path";
import fs from "fs";
import { spawn } from "child_process";
import { config } from "./config";
import { downloadFile, uploadDirectory } from "./lib/s3";
import { query } from "./lib/db"; // هذا يشير إلى الملف الموجود داخل lib

const QUEUE_NAME = "video-transcoding-queue";

// إعدادات Redis
const connection = new IORedis(config.redisUrl, {
  maxRetriesPerRequest: null,
});

// دالة تشغيل السكربت
function runFFmpegScript(inputPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const scriptPath = path.resolve(__dirname, "../scripts/encode_master.sh");
    const workDir = path.dirname(inputPath);
    const fileName = path.basename(inputPath);

    if (!fs.existsSync(scriptPath)) {
      return reject(new Error(`Script not found at: ${scriptPath}`));
    }

    console.log(`[FFmpeg] Spawning Bash inside: ${workDir}`);

    const process = spawn("bash", [scriptPath, fileName], {
      cwd: workDir,
      stdio: ["ignore", "pipe", "pipe"],
    });

    process.stdout.on("data", (d) =>
      console.log(`[FFmpeg Out] ${d.toString().trim()}`),
    );
    process.stderr.on("data", (d) =>
      console.error(`[FFmpeg Err] ${d.toString().trim()}`),
    );

    process.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`FFmpeg script failed with exit code ${code}`));
    });
  });
}

// دالة معالجة الوظيفة
const processJob = async (job: Job) => {
  const { videoId, s3Key } = job.data;
  console.log(`[Worker] Starting job ${job.id} for video ${videoId}`);

  const tempDir = path.resolve(__dirname, `../temp/${videoId}`);
  const inputPath = path.join(tempDir, "source.mp4");

  try {
    if (!fs.existsSync(tempDir)) fs.mkdirSync(tempDir, { recursive: true });

    await query("UPDATE videos SET status = 'PROCESSING' WHERE id = $1", [
      videoId,
    ]);

    // 1. التنزيل
    console.log("[Worker] Downloading source file...");
    await downloadFile(s3Key, inputPath);

    // 2. المعالجة
    console.log("[Worker] Transcoding...");
    await runFFmpegScript(inputPath);

    // 3. الرفع
    const s3TargetPrefix = `hls/${videoId}`;
    console.log("[Worker] Uploading HLS files...");
    await uploadDirectory(tempDir, s3TargetPrefix);

    // 4. الحفظ
    const playlistUrl = `https://${config.aws.bucket}.fly.storage.tigris.dev/${s3TargetPrefix}/master.m3u8`;
    await query(
      "UPDATE videos SET status = 'READY', hls_playlist_path = $1 WHERE id = $2",
      [playlistUrl, videoId],
    );

    console.log(`[Worker] Job ${job.id} Completed!`);
  } catch (error) {
    console.error(`[Worker] Job ${job.id} Failed:`, error);
    await query("UPDATE videos SET status = 'FAILED' WHERE id = $1", [videoId]);
    throw error;
  } finally {
    if (fs.existsSync(tempDir))
      fs.rmSync(tempDir, { recursive: true, force: true });
  }
};

// إنشاء الوركر (مع التصحيح الخاص بـ connection)
export const worker = new Worker(QUEUE_NAME, processJob, {
  connection: connection as any, // <--- الحل الذي قمت به (صحيح 100%)
  concurrency: 1,
  drainDelay: 5000,
  lockDuration: 60000,
  lockRenewTime: 15000,
});
