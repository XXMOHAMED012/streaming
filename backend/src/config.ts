import dotenv from "dotenv";
dotenv.config();

const checkEnv = (key: string) => {
  if (!process.env[key]) {
    throw new Error(`Missing environment variable: ${key}`);
  }
  return process.env[key]!;
};

export const config = {
  port: process.env.PORT || 8080,
  dbUrl: checkEnv("DATABASE_URL"),
  redisUrl: checkEnv("REDIS_URL"),
  aws: {
    accessKeyId: checkEnv("AWS_ACCESS_KEY_ID"),
    secretAccessKey: checkEnv("AWS_SECRET_ACCESS_KEY"),
    region: process.env.AWS_REGION || "auto",
    endpoint: checkEnv("AWS_ENDPOINT"),
    bucket: checkEnv("BUCKET_NAME"),
  },
};
