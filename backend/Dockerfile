# 1. استخدام صورة Node.js خفيفة مبنية على Debian (لأنها تدعم apt-get بشكل ممتاز)
FROM node:20-slim

# 2. تثبيت المكتبات الضرورية للنظام (FFmpeg + Python للبناء)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    ffmpeg \
    python3 \
    make \
    g++ \
    bc \
    ca-certificates \
    curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 3. تحديد مجلد العمل
WORKDIR /app

# 4. نسخ ملفات تعريف المشروع وتثبيت المكتبات
COPY package*.json ./
RUN npm install

# 5. نسخ باقي ملفات المشروع (الكود + السكربتات)
COPY . .

# 6. بناء المشروع (تحويل TS إلى JS)
RUN npm run build

# 7. إعطاء صلاحية التنفيذ لسكربت FFmpeg (مهم جداً)
RUN chmod +x scripts/encode_master.sh

# 8. المنفذ الافتراضي
EXPOSE 8080

# الأمر الافتراضي (سيتم تغييره بواسطة fly.toml حسب نوع العملية)
CMD ["npm", "start"]