-- 案件录入基础配置：事项处置主管部门与单元网格。
-- 前置：已执行 supabase-components-matters.sql。
-- 本脚本不创建管理部件或管理事项实例，仅为后续“案件保存时自动创建事项实例”准备国标必填数据。

begin;

create table if not exists public.handling_departments (
  department_label text primary key,
  organization_code varchar(18) not null unique
    check (organization_code ~ '^[0-9A-Z]{18}$'),
  organization_name varchar(100) not null,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.handling_departments is
  '事项处置主管部门配置。department_label 与 issue_dictionary.default_department 对应；organization_code 为统一社会信用代码。';

create table if not exists public.unit_grids (
  grid_identifier varchar(15) primary key
    check (grid_identifier ~ '^[0-9A-Z]{15}$'),
  grid_name varchar(100) not null,
  administrative_division_code varchar(6) not null
    check (administrative_division_code ~ '^[0-9]{6}$'),
  administrative_division_name varchar(100),
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.unit_grids is
  '单元网格配置。grid_identifier 对应 GB/T 47678.3 的所在单元网格标识码；后续管理事项和管理部件均从此表选择。';

alter table public.inspection_records
  add column if not exists supervising_org_code text,
  add column if not exists supervising_org_name text,
  add column if not exists grid_identifier text;

create index if not exists inspection_records_grid_identifier_idx
  on public.inspection_records (grid_identifier)
  where grid_identifier is not null;
create index if not exists inspection_records_supervising_org_code_idx
  on public.inspection_records (supervising_org_code)
  where supervising_org_code is not null;
create index if not exists unit_grids_division_active_idx
  on public.unit_grids (administrative_division_code, sort_order)
  where is_active;

comment on column public.inspection_records.supervising_org_code is
  '事项处置主管部门统一社会信用代码；后续自动创建管理事项实例时写入。';
comment on column public.inspection_records.supervising_org_name is
  '事项处置主管部门名称；后续自动创建管理事项实例时写入。';
comment on column public.inspection_records.grid_identifier is
  '所在单元网格标识码；后续自动创建管理事项实例时写入。';

alter table public.handling_departments enable row level security;
alter table public.unit_grids enable row level security;

drop policy if exists "authenticated users can read handling departments" on public.handling_departments;
create policy "authenticated users can read handling departments"
  on public.handling_departments for select to authenticated using (true);
drop policy if exists "admins manage handling departments" on public.handling_departments;
create policy "admins manage handling departments"
  on public.handling_departments for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "authenticated users can read unit grids" on public.unit_grids;
create policy "authenticated users can read unit grids"
  on public.unit_grids for select to authenticated using (true);
drop policy if exists "admins manage unit grids" on public.unit_grids;
create policy "admins manage unit grids"
  on public.unit_grids for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

commit;
