// 1. تعريف شكل البيانات في قاعدة البيانات
export interface VideoRecord {
  id: string;
  title: string;
  status: "PENDING" | "QUEUED" | "PROCESSING" | "READY" | "FAILED";
  original_file_path?: string;
  hls_playlist_path?: string;
  created_at: Date;
}

// 2. تعريف بيانات المهمة التي ترسل للوركر
export interface TranscodeJobData {
  videoId: string;
  s3Key: string; 
}

// 3. تعريف مدخلات الـ API
export interface UploadRequestBody {
  title: string;
  filename: string;
}

export interface ProcessRequestBody {
  videoId: string;
  s3Key: string;
}
