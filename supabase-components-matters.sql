-- 城市运行管理服务平台：管理部件、管理事项及属性定义基线
-- 依据：GB/T 47678.5-2026 第4章、第5章及表2、表3；
--       GB/T 47678.7-2026 4.8（字段名称、缩写名、字段类型、长度、约束/条件、说明）。
--
-- 执行前置：已执行 supabase-issue-dictionary.sql、supabase-issue-dictionary-v2.sql、
--           supabase-gb47678.5-directory.sql。
-- 本脚本已包含此前 supabase-record-standard-fields.sql 中的 inspection_records 新字段，
-- 因此在尚未执行旧脚本的情况下，只执行本脚本即可。

begin;

-- 1. 管理部件属性定义：标准18项 + 各城市可按类型追加的扩展项。
create table if not exists public.component_attribute_definitions (
  id uuid primary key default gen_random_uuid(),
  standard_ref text not null default 'GB/T 47678.5-2026',
  component_type_code text not null default '*'
    check (component_type_code = '*' or component_type_code ~ '^[0-9]{5}$'),
  field_name text not null,
  field_abbr text not null,
  field_type text not null
    check (field_type in ('字符型', '数值型', '日期型', '日期时间型', '布尔型')),
  field_length integer check (field_length is null or field_length > 0),
  requirement char(1) not null check (requirement in ('M', 'C', 'O')),
  description text not null default '',
  is_standard boolean not null default true,
  is_active boolean not null default true,
  display_order integer not null default 100 check (display_order > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (standard_ref, component_type_code, field_abbr)
);

comment on table public.component_attribute_definitions is
  '管理部件属性定义。component_type_code=* 表示 GB/T 47678.5-2026 表2的通用属性；具体五位类别代码可追加地方扩展属性。';

-- 2. 管理事项属性定义：标准6项 + 各城市可按类型追加的扩展项。
create table if not exists public.matter_attribute_definitions (
  id uuid primary key default gen_random_uuid(),
  standard_ref text not null default 'GB/T 47678.5-2026',
  matter_type_code text not null default '*'
    check (matter_type_code = '*' or matter_type_code ~ '^[0-9]{5}$'),
  field_name text not null,
  field_abbr text not null,
  field_type text not null
    check (field_type in ('字符型', '数值型', '日期型', '日期时间型', '布尔型')),
  field_length integer check (field_length is null or field_length > 0),
  requirement char(1) not null check (requirement in ('M', 'C', 'O')),
  description text not null default '',
  is_standard boolean not null default true,
  is_active boolean not null default true,
  display_order integer not null default 100 check (display_order > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (standard_ref, matter_type_code, field_abbr)
);

comment on table public.matter_attribute_definitions is
  '管理事项属性定义。matter_type_code=* 表示 GB/T 47678.5-2026 表3的通用属性；具体五位类别代码可追加地方扩展属性。';

-- 3. 长期存在的城市资产。表2的18项标准属性均做成固定字段；
--    extension_attributes 仅承载符合第4.4.2条的地方扩展项。
create table if not exists public.management_components (
  id uuid primary key default gen_random_uuid(),
  standard_ref text not null default 'GB/T 47678.5-2026',
  component_kind text not null default '管理部件'
    check (component_kind = '管理部件'),
  component_identifier varchar(17) not null unique
    check (component_identifier ~ '^[0-9]{17}$'),
  component_type_code varchar(5) not null
    check (component_type_code ~ '^[0-9]{5}$'),
  component_name varchar(30) not null,
  administrative_division_code varchar(6) not null
    check (administrative_division_code ~ '^[0-9]{6}$'),
  administrative_division_name varchar(100),
  supervising_org_code varchar(18) not null,
  supervising_org_name varchar(100) not null,
  ownership_org_code varchar(18),
  ownership_org_name varchar(100),
  maintenance_org_code varchar(18),
  maintenance_org_name varchar(100),
  grid_identifier varchar(15) not null,
  component_status varchar(10) not null,
  initial_date date not null,
  changed_date date,
  data_source varchar(30),
  remarks varchar(1000),
  street_code varchar(9),
  street_name varchar(50),
  community_code varchar(12),
  community_name varchar(50),
  longitude numeric(10, 7),
  latitude numeric(10, 7),
  coordinate_system text not null default 'CGCS2000',
  spatial_accuracy_class char(1) check (spatial_accuracy_class in ('A', 'B', 'C')),
  extension_attributes jsonb not null default '{}'::jsonb
    check (jsonb_typeof(extension_attributes) = 'object'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint management_components_type_fkey
    foreign key (standard_ref, component_kind, component_type_code)
    references public.issue_dictionary (standard_ref, matter_kind, standard_code),
  constraint management_components_identifier_division_check
    check (left(component_identifier, 6) = administrative_division_code),
  constraint management_components_identifier_type_check
    check (substring(component_identifier from 7 for 5) = component_type_code)
);

comment on table public.management_components is
  '长期存在的城市管理部件（资产）实例。管理部件标识码=6位行政区划代码+2位大类代码+3位小类代码+6位顺序代码，共17位。';

-- 4. 每一次实际发现的管理事项。表3的6项标准属性做成固定字段；
--    同一类型在不同地点可重复发生，因此 matter_code 不能设为唯一键。
create table if not exists public.management_matters (
  id uuid primary key default gen_random_uuid(),
  standard_ref text not null default 'GB/T 47678.5-2026',
  matter_kind text not null default '管理事项'
    check (matter_kind = '管理事项'),
  matter_code varchar(11) not null
    check (matter_code ~ '^[0-9]{11}$'),
  matter_type_code varchar(5) not null
    check (matter_type_code ~ '^[0-9]{5}$'),
  matter_name varchar(30) not null,
  administrative_division_code varchar(6) not null
    check (administrative_division_code ~ '^[0-9]{6}$'),
  administrative_division_name varchar(100),
  supervising_org_code varchar(18) not null,
  supervising_org_name varchar(100) not null,
  incident_location varchar(256) not null,
  grid_identifier varchar(15) not null,
  component_id uuid references public.management_components (id) on delete set null,
  discovered_at timestamptz not null default now(),
  reported_at timestamptz not null default now(),
  source text not null default '人工巡查',
  longitude numeric(10, 7),
  latitude numeric(10, 7),
  coordinate_system text not null default 'CGCS2000',
  extension_attributes jsonb not null default '{}'::jsonb
    check (jsonb_typeof(extension_attributes) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint management_matters_type_fkey
    foreign key (standard_ref, matter_kind, matter_type_code)
    references public.issue_dictionary (standard_ref, matter_kind, standard_code),
  constraint management_matters_code_division_check
    check (left(matter_code, 6) = administrative_division_code),
  constraint management_matters_code_type_check
    check (substring(matter_code from 7 for 5) = matter_type_code)
);

comment on table public.management_matters is
  '一次实际发生的管理事项。事项代码=6位行政区划代码+2位大类代码+3位小类代码，共11位；不作为事项实例唯一标识。';

-- 5. 原案件表保留为流程/工单表；补充行政区划、国标快照以及部件/事项关联。
alter table public.inspection_records
  add column if not exists administrative_division_code text,
  add column if not exists administrative_division_name text,
  add column if not exists standard_kind text,
  add column if not exists standard_ref text,
  add column if not exists standard_code text,
  add column if not exists standard_name text,
  add column if not exists component_id uuid,
  add column if not exists matter_id uuid;

create index if not exists inspection_records_standard_code_idx
  on public.inspection_records (standard_ref, standard_kind, standard_code)
  where standard_code is not null;
create index if not exists inspection_records_administrative_division_code_idx
  on public.inspection_records (administrative_division_code)
  where administrative_division_code is not null;
create index if not exists inspection_records_component_id_idx
  on public.inspection_records (component_id)
  where component_id is not null;
create index if not exists inspection_records_matter_id_idx
  on public.inspection_records (matter_id)
  where matter_id is not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inspection_records_component_id_fkey') then
    alter table public.inspection_records
      add constraint inspection_records_component_id_fkey
      foreign key (component_id) references public.management_components (id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'inspection_records_matter_id_fkey') then
    alter table public.inspection_records
      add constraint inspection_records_matter_id_fkey
      foreign key (matter_id) references public.management_matters (id) on delete set null;
  end if;
end;
$$;

comment on column public.inspection_records.administrative_division_code is
  '县级及以上行政区划六码代码，遵循 GB/T 2260。';
comment on column public.inspection_records.administrative_division_name is
  '行政区划名称。';
comment on column public.inspection_records.standard_kind is
  'GB/T 47678.5-2026 国标大类：管理部件或管理事项。';
comment on column public.inspection_records.standard_ref is
  '案件国标快照的标准编号，例如 GB/T 47678.5-2026。';
comment on column public.inspection_records.standard_code is
  '案件国标快照的五位类别代码。';
comment on column public.inspection_records.standard_name is
  '案件国标快照的管理部件或管理事项名称。';
comment on column public.inspection_records.component_id is
  '关联的长期城市管理部件；无关联部件的事项可为空。';
comment on column public.inspection_records.matter_id is
  '关联的管理事项实例。';

-- 6. 查询与统计索引。
create index if not exists management_components_division_type_idx
  on public.management_components (administrative_division_code, component_type_code)
  where is_active;
create index if not exists management_components_grid_idx
  on public.management_components (grid_identifier)
  where is_active;
create index if not exists management_components_extension_attributes_idx
  on public.management_components using gin (extension_attributes);
create index if not exists management_matters_discovered_at_idx
  on public.management_matters (discovered_at desc);
create index if not exists management_matters_division_type_idx
  on public.management_matters (administrative_division_code, matter_type_code, discovered_at desc);
create index if not exists management_matters_component_id_idx
  on public.management_matters (component_id)
  where component_id is not null;
create index if not exists management_matters_extension_attributes_idx
  on public.management_matters using gin (extension_attributes);

-- 7. 导入 GB/T 47678.5-2026 表2、表3的标准属性定义。
insert into public.component_attribute_definitions (
  standard_ref, component_type_code, field_name, field_abbr, field_type,
  field_length, requirement, description, is_standard, display_order
) values
  ('GB/T 47678.5-2026', '*', '管理部件标识码', 'GLBJBSM', '字符型', 17, 'M', '管理部件的标识码。', true, 1),
  ('GB/T 47678.5-2026', '*', '管理部件名称', 'GLBJMC', '字符型', 30, 'M', '管理部件的标准名称。', true, 2),
  ('GB/T 47678.5-2026', '*', '主管部门代码', 'ZGBMDM', '字符型', 18, 'M', '统一社会信用代码。', true, 3),
  ('GB/T 47678.5-2026', '*', '主管部门名称', 'ZGBMMC', '字符型', 100, 'M', '管理部件主管部门的全称。', true, 4),
  ('GB/T 47678.5-2026', '*', '权属单位代码', 'QSDWDM', '字符型', 18, 'O', '统一社会信用代码。', true, 5),
  ('GB/T 47678.5-2026', '*', '权属单位名称', 'QSDWMC', '字符型', 100, 'O', '管理部件权属单位的全称。', true, 6),
  ('GB/T 47678.5-2026', '*', '养护单位代码', 'YHDWDM', '字符型', 18, 'O', '统一社会信用代码。', true, 7),
  ('GB/T 47678.5-2026', '*', '养护单位名称', 'YHDWMC', '字符型', 100, 'O', '管理部件养护单位的全称。', true, 8),
  ('GB/T 47678.5-2026', '*', '所在单元网格标识码', 'SZDYWGBSM', '字符型', 15, 'M', '应符合 GB/T 47678.3 的规定。', true, 9),
  ('GB/T 47678.5-2026', '*', '管理部件状态', 'GLBJZT', '字符型', 10, 'M', '如完好、破损、丢失、废弃、移除等。', true, 10),
  ('GB/T 47678.5-2026', '*', '初始日期', 'CSRQ', '日期型', 8, 'M', '管理部件数据普查的初始日期，格式 YYYYMMDD。', true, 11),
  ('GB/T 47678.5-2026', '*', '变更日期', 'BGRQ', '日期型', 8, 'C', '管理部件数据变更调查日期；首次普查为空。', true, 12),
  ('GB/T 47678.5-2026', '*', '数据来源', 'SJLY', '字符型', 30, 'O', '包括实测、地形图、基础地理数据、其他。', true, 13),
  ('GB/T 47678.5-2026', '*', '备注', 'BZ', '字符型', 1000, 'O', '如变更原因、权属确认情况等。', true, 14),
  ('GB/T 47678.5-2026', '*', '所在街道（镇、乡）代码', 'SZJDDM', '字符型', 9, 'O', '应符合行政区划代码主管部门的规定。', true, 15),
  ('GB/T 47678.5-2026', '*', '所在街道（镇、乡）名称', 'SZJDMC', '字符型', 50, 'O', '所在街道（镇、乡）的全称。', true, 16),
  ('GB/T 47678.5-2026', '*', '所在社区（村）代码', 'SZSQDM', '字符型', 12, 'O', '管理部件所在社区（村）的代码。', true, 17),
  ('GB/T 47678.5-2026', '*', '所在社区（村）名称', 'SZSQMC', '字符型', 50, 'O', '管理部件所在社区（村）的全称。', true, 18)
on conflict (standard_ref, component_type_code, field_abbr) do update set
  field_name = excluded.field_name,
  field_type = excluded.field_type,
  field_length = excluded.field_length,
  requirement = excluded.requirement,
  description = excluded.description,
  is_standard = true,
  display_order = excluded.display_order,
  updated_at = now();

insert into public.matter_attribute_definitions (
  standard_ref, matter_type_code, field_name, field_abbr, field_type,
  field_length, requirement, description, is_standard, display_order
) values
  ('GB/T 47678.5-2026', '*', '事项代码', 'SXDM', '字符型', 11, 'M', '事项分类代码。', true, 1),
  ('GB/T 47678.5-2026', '*', '事项名称', 'SXMC', '字符型', 30, 'M', '事项的标准名称。', true, 2),
  ('GB/T 47678.5-2026', '*', '主管部门代码', 'ZGBMDM', '字符型', 18, 'M', '统一社会信用代码。', true, 3),
  ('GB/T 47678.5-2026', '*', '主管部门名称', 'ZGBMMC', '字符型', 100, 'M', '事项处置主管部门的全称。', true, 4),
  ('GB/T 47678.5-2026', '*', '事发位置', 'SFWZ', '字符型', 256, 'M', '事项发生地的位置描述，应符合 GB/T 47678.4 的规定。', true, 5),
  ('GB/T 47678.5-2026', '*', '所在单元网格标识码', 'SZDYWGBSM', '字符型', 15, 'M', '应符合 GB/T 47678.3 的规定。', true, 6)
on conflict (standard_ref, matter_type_code, field_abbr) do update set
  field_name = excluded.field_name,
  field_type = excluded.field_type,
  field_length = excluded.field_length,
  requirement = excluded.requirement,
  description = excluded.description,
  is_standard = true,
  display_order = excluded.display_order,
  updated_at = now();

-- 8. RLS：属性定义可供已登录用户读取；部件/事项仅管理员或关联案件的创建人、负责人读取。
alter table public.component_attribute_definitions enable row level security;
alter table public.matter_attribute_definitions enable row level security;
alter table public.management_components enable row level security;
alter table public.management_matters enable row level security;

drop policy if exists "authenticated users can read component attribute definitions" on public.component_attribute_definitions;
create policy "authenticated users can read component attribute definitions"
  on public.component_attribute_definitions for select to authenticated
  using (true);
drop policy if exists "admins manage component attribute definitions" on public.component_attribute_definitions;
create policy "admins manage component attribute definitions"
  on public.component_attribute_definitions for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "authenticated users can read matter attribute definitions" on public.matter_attribute_definitions;
create policy "authenticated users can read matter attribute definitions"
  on public.matter_attribute_definitions for select to authenticated
  using (true);
drop policy if exists "admins manage matter attribute definitions" on public.matter_attribute_definitions;
create policy "admins manage matter attribute definitions"
  on public.matter_attribute_definitions for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "admins or linked users read management components" on public.management_components;
create policy "admins or linked users read management components"
  on public.management_components for select to authenticated
  using (
    private.is_admin()
    or exists (
      select 1 from public.inspection_records record
      where record.component_id = management_components.id
        and (record.assignee_id = auth.uid() or record.created_by = auth.uid())
    )
  );
drop policy if exists "admins manage management components" on public.management_components;
create policy "admins manage management components"
  on public.management_components for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "admins or linked users read management matters" on public.management_matters;
create policy "admins or linked users read management matters"
  on public.management_matters for select to authenticated
  using (
    private.is_admin()
    or exists (
      select 1 from public.inspection_records record
      where record.matter_id = management_matters.id
        and (record.assignee_id = auth.uid() or record.created_by = auth.uid())
    )
  );
drop policy if exists "admins manage management matters" on public.management_matters;
create policy "admins manage management matters"
  on public.management_matters for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

commit;
