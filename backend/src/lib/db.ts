import { Pool } from "pg";
import { config } from "../config";

// نستخدم Pool لأنه أفضل في الأداء من Client العادي
const pool = new Pool({
  connectionString: config.dbUrl,
  ssl: {
    // التغيير هنا: استخدام verify-full إذا كان مدعوماً،
    // أو rejectUnauthorized: false للسيرفرات التي لا تملك شهادات رسمية (مثل Neon أحياناً في وضع التطوير)
    rejectUnauthorized: false,
  },
  // إضافة هذا السطر لمنع ظهور التحذير في النسخ الجديدة من pg
  max: 20,
});

// دالة مساعدة لتنفيذ الاستعلامات مع Types
export const query = async (text: string, params?: any[]) => {
  return pool.query(text, params);
};
