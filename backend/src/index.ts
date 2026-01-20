import Fastify, { FastifyRequest, FastifyReply } from "fastify";
import cors from "@fastify/cors";
import { query } from "./lib/db";
import { generateUploadUrl } from "./lib/s3";
import { videoQueue } from "./lib/queue";
import { UploadRequestBody, ProcessRequestBody } from "./types";
import { config } from "./config";

const server = Fastify({
  logger: true,
  bodyLimit: 1048576 * 10,
});

server.register(cors, {
  origin: "*",
  methods: ["GET", "POST", "PUT", "DELETE"],
});

server.get("/", async () => {
  return { status: "OK", service: "Qudurat Backend Engine" };
});

// 1. طلب رابط الرفع
server.post(
  "/upload/init",
  async (
    req: FastifyRequest<{ Body: UploadRequestBody }>,
    reply: FastifyReply,
  ) => {
    try {
      // التعديل: اللوحة سترسل filename و title
      const { title, filename } = req.body;

      if (!title || !filename) {
        return reply.code(400).send({ error: "Missing title or filename" });
      }

      const res = await query(
        "INSERT INTO videos (title, status) VALUES ($1, 'PENDING') RETURNING id",
        [title],
      );

      if (res.rows.length === 0)
        throw new Error("Failed to insert video into DB");

      const videoId = res.rows[0].id;
      const s3Key = `raw/${videoId}/${filename}`;
      const uploadUrl = await generateUploadUrl(s3Key);

      // الرد يجب أن يطابق ما تتوقعه اللوحة
      return reply.send({
        videoId,
        uploadUrl,
        s3Key, // key ضروري للخطوة التالية
      });
    } catch (error) {
      req.log.error(error);
      return reply.code(500).send({ error: "Internal Server Error" });
    }
  },
);

// 2. بدء المعالجة
server.post(
  "/upload/process",
  async (
    req: FastifyRequest<{ Body: ProcessRequestBody }>,
    reply: FastifyReply,
  ) => {
    try {
      const { videoId, s3Key } = req.body;

      if (!videoId || !s3Key) {
        return reply.code(400).send({ error: "Missing videoId or s3Key" });
      }

      const updateRes = await query(
        "UPDATE videos SET status = 'QUEUED', original_file_path = $1 WHERE id = $2 RETURNING id",
        [s3Key, videoId],
      );

      if (updateRes.rowCount === 0)
        return reply.code(404).send({ error: "Video not found" });

      await videoQueue.add(
        "transcode",
        { videoId, s3Key },
        {
          attempts: 3,
          backoff: { type: "exponential", delay: 1000 },
        },
      );

      req.log.info(`Video ${videoId} queued.`);
      return reply.send({ success: true, status: "QUEUED" });
    } catch (error) {
      req.log.error(error);
      return reply.code(500).send({ error: "Internal Server Error" });
    }
  },
);

// 3. (جديد وهام) مسار فحص الحالة للوحة التحكم
server.get<{ Params: { id: string } }>(
  "/videos/status/:id",
  async (req, reply) => {
    try {
      const { id } = req.params;
      const res = await query(
        "SELECT status, hls_playlist_path FROM videos WHERE id = $1",
        [id],
      );

      if (res.rows.length === 0) {
        return reply.code(404).send({ error: "Video not found" });
      }

      return reply.send(res.rows[0]);
    } catch (error) {
      req.log.error(error);
      return reply.code(500).send({ error: "Internal Error" });
    }
  },
);

const start = async () => {
  try {
    const port = Number(config.port) || 8080;
    await server.listen({ port, host: "0.0.0.0" });
    console.log(`🚀 API Server running at http://0.0.0.0:${port}`);
  } catch (err) {
    server.log.error(err);
    process.exit(1);
  }
};

start();
