-- 为巡查记录保存照片 AI 辅助识别结果。
-- 在 Supabase SQL Editor 运行一次；此字段仅保存分类、建议等 JSON，不保存 API 密钥。

alter table public.inspection_records
  add column if not exists ai_analysis jsonb;

comment on column public.inspection_records.ai_analysis is
  '现场照片 AI 辅助识别结果；需由人工复核后使用。';
