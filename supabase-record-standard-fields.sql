-- 为新案件保存行政区划与 GB/T 47678.5-2026 国标事项标识。
-- 历史案件保持为空；新录入案件由前端写入行政区划、标准号、五位代码和事项名称。

begin;

alter table public.inspection_records
  add column if not exists administrative_division_code text,
  add column if not exists administrative_division_name text,
  add column if not exists standard_kind text,
  add column if not exists standard_ref text,
  add column if not exists standard_code text,
  add column if not exists standard_name text;

create index if not exists inspection_records_standard_code_idx
  on public.inspection_records (standard_ref, standard_kind, standard_code)
  where standard_code is not null;

create index if not exists inspection_records_administrative_division_code_idx
  on public.inspection_records (administrative_division_code)
  where administrative_division_code is not null;

comment on column public.inspection_records.administrative_division_code is
  '县级及以上行政区划六码代码，遵循 GB/T 2260，例如 440305。';
comment on column public.inspection_records.administrative_division_name is
  '行政区划名称，例如 广东省深圳市南山区。';
comment on column public.inspection_records.standard_kind is
  'GB/T 47678.5-2026 国标大类：管理部件或管理事项。';

comment on column public.inspection_records.standard_ref is
  '案件采用的标准编号，例如 GB/T 47678.5-2026。';
comment on column public.inspection_records.standard_code is
  'GB/T 47678.5-2026 管理部件或管理事项的五位代码；仅新案件按确认结果写入。';
comment on column public.inspection_records.standard_name is
  'GB/T 47678.5-2026 管理部件或管理事项名称；与 standard_code 配套保存。';

commit;
