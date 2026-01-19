# استخدم صورة Linux Debian خفيفة
FROM node:20-bullseye-slim

# 1. تثبيت FFmpeg و bc (الأدوات المطلوبة لسكربت الباش)
RUN apt-get update && apt-get install -y \
    ffmpeg \
    bc \
    && rm -rf /var/lib/apt/lists/*

# 2. إعداد مجلد العمل
WORKDIR /app

# 3. نسخ ملفات المشروع وتثبيت التبعيات
COPY package*.json ./
RUN npm install --production

# 4. نسخ السكربتات والكود المصدري
COPY scripts ./scripts
COPY dist ./dist  
# (ملاحظة: نفترض أنك قمت بعمل build للـ TypeScript إلى مجلد dist)

# 5. إعطاء صلاحية التنفيذ لسكربت الترميز
RUN chmod +x ./scripts/encode_master.sh

# 6. المنافذ (للـ API)
EXPOSE 8080

# الأمر الافتراضي (سنغيره في Fly.toml)
CMD ["node", "dist/api.js"]