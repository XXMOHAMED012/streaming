import { Queue, Worker } from "bullmq";
import IORedis from "ioredis";
import { config } from "../config";

// 1. إعداد اتصال Redis مع حلول مشاكل الشبكة
const connection = new IORedis(config.redisUrl, {
  maxRetriesPerRequest: null,
});

export const QUEUE_NAME = "video-transcoding-queue";

// 2. إنشاء الطابور
export const videoQueue = new Queue(QUEUE_NAME, {
  connection: connection as any,
});

// 3. دالة لإنشاء وركر
export const createWorker = (processor: (job: any) => Promise<void>) => {
  return new Worker(QUEUE_NAME, processor, {
    connection: connection as any,
    concurrency: 1,

    // --- إعدادات توفير التكلفة لـ Upstash ---

    // 1. أهم إعداد: التأخير عند الفراغ
    // إذا لم يجد وظائف، انتظر 5 ثوانٍ (5000ms) قبل السؤال مجدداً
    // الافتراضي كان شبه فوري، مما يسبب آلاف الطلبات
    drainDelay: 5000,

    // 2. مدة القفل (Lock)
    // نزيد المدة لتقليل عدد مرات تجديد القفل أثناء معالجة الفيديو الطويل
    lockDuration: 30000, // 30 ثانية

    // 3. تقليل معدل تحديث القفل
    // الافتراضي يجدد القفل كل نصف المدة، هنا نجعله أقل تكراراً
    lockRenewTime: 15000,

    // 4. إيقاف المقاييس (Metrics)
    // BullMQ يقوم بتسجيل إحصائيات في Redis بشكل دوري، هذا يستهلك طلبات
    // نوقفها لأننا لا نستخدم لوحة تحكم BullMQ حالياً
    metrics: {
      maxDataPoints: 0, // 0 يعني تعطيل جمع البيانات
    },
  });
};
