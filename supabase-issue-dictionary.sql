-- 城市运行管理服务平台标准目录与案件来源基线
-- 目录结构对齐 GB/T 47678.5-2026《城市运行管理服务平台 第5部分：管理部件和事项》。
-- 该标准已于 2026-07-01 实施，并全部代替 GB/T 30428.2-2013。
-- 在 Supabase SQL Editor 一次性执行；执行前建议先导出 inspection_records 数据。

begin;

alter table public.inspection_records
  add column if not exists source text;

update public.inspection_records
set source = '人工巡查'
where source is null or btrim(source) = '';

alter table public.inspection_records
  alter column source set default '人工巡查';

create table if not exists public.issue_dictionary (
  id uuid primary key default gen_random_uuid(),
  standard_ref text not null default 'GB/T 47678.5-2026',
  standard_code text,
  matter_kind text not null default '管理事项'
    check (matter_kind in ('管理部件', '管理事项')),
  category text not null,
  subcategory text not null default '',
  standard_name text not null,
  default_department text not null,
  default_priority text not null default '一般'
    check (default_priority in ('一般', '较高', '高', '待确认')),
  suggested_deadline_days integer not null default 3
    check (suggested_deadline_days between 0 and 365),
  applicable_sources text[] not null default array['人工巡查'],
  keywords text[] not null default array[]::text[],
  is_local_extension boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (standard_ref, matter_kind, standard_code)
);

create index if not exists issue_dictionary_active_order_idx
  on public.issue_dictionary (is_active, sort_order, category);

alter table public.issue_dictionary enable row level security;

drop policy if exists "authenticated users can read issue dictionary" on public.issue_dictionary;
create policy "authenticated users can read issue dictionary"
  on public.issue_dictionary for select to authenticated
  using (true);

drop policy if exists "admins manage issue dictionary" on public.issue_dictionary;
create policy "admins manage issue dictionary"
  on public.issue_dictionary for all to authenticated
  using (private.is_admin())
  with check (private.is_admin());

comment on table public.issue_dictionary is
  '标准问题目录。GB/T 47678.5-2026 的管理部件和管理事项均使用两位大类码加三位小类码，因此唯一键必须包含 matter_kind；地方增补项必须标记 is_local_extension=true。';

commit;
