import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import fs from "fs";
import path from "path";
import { config } from "../config";

const s3 = new S3Client({
  region: config.aws.region,
  endpoint: config.aws.endpoint,
  credentials: {
    accessKeyId: config.aws.accessKeyId,
    secretAccessKey: config.aws.secretAccessKey,
  },
});

export const BUCKET = config.aws.bucket;

// ... (Generate & Download functions remain the same) ...
export async function generateUploadUrl(key: string): Promise<string> {
  const command = new PutObjectCommand({ Bucket: BUCKET, Key: key });
  return getSignedUrl(s3, command, { expiresIn: 3600 });
}

export async function downloadFile(
  key: string,
  localPath: string,
): Promise<void> {
  const command = new GetObjectCommand({ Bucket: BUCKET, Key: key });
  const response = await s3.send(command);
  if (!response.Body) throw new Error("Empty response body");
  const fileStream = fs.createWriteStream(localPath);
  const stream = response.Body as any;
  return new Promise((resolve, reject) => {
    stream.pipe(fileStream).on("finish", resolve).on("error", reject);
  });
}

// الدالة المصححة للرفع (تحدد Content-Type وتتجاهل الملف الأصلي)
export async function uploadDirectory(localDir: string, s3Prefix: string) {
  const files = fs.readdirSync(localDir);

  for (const file of files) {
    const fullPath = path.join(localDir, file);

    // نتجاهل المجلدات والملف المصدري
    if (fs.lstatSync(fullPath).isDirectory()) continue;
    if (file === "source.mp4") continue;

    const fileContent = fs.readFileSync(fullPath);

    // تحديد نوع الملف (السر في عمل الفيديو)
    let contentType = "application/octet-stream";
    if (file.endsWith(".m3u8")) contentType = "application/vnd.apple.mpegurl";
    else if (file.endsWith(".ts")) contentType = "video/MP2T";

    console.log(`[S3] Uploading ${file} as ${contentType}`);

    const command = new PutObjectCommand({
      Bucket: BUCKET,
      Key: `${s3Prefix}/${file}`,
      Body: fileContent,
      ContentType: contentType, // <--- هذا السطر هو الأهم
      ACL: "public-read",
    });

    await s3.send(command);
  }
}
