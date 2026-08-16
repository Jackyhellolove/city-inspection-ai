-- 新建案件时自动创建管理事项实例（原子事务）。
--
-- 前置：已执行以下脚本：
--   1. supabase-issue-dictionary.sql
--   2. supabase-issue-dictionary-v2.sql
--   3. supabase-gb47678.5-directory.sql
--   4. supabase-components-matters.sql
--   5. supabase-case-intake-config.sql
--   6. supabase-workflow-v3.sql
--
-- 用途：管理员从案件录入页面保存时，数据库在同一事务内：
--   - 校验国标管理事项、处置主管部门、单元网格和负责人；
--   - 创建一条 management_matters（管理事项实例）；
--   - 创建一条 inspection_records（案件）并写入 matter_id；
--   - 写入首条处置时间线。
-- 任一环节失败都会整体回滚，不会遗留“孤立事项”或“孤立案件”。

begin;

create or replace function public.create_inspection_case_with_matter(
  p_record_no text,
  p_description text,
  p_location text,
  p_administrative_division_code text,
  p_administrative_division_name text,
  p_standard_ref text,
  p_standard_code text,
  p_grid_identifier text,
  p_assignee_id uuid,
  p_owner_name text,
  p_status text default '处理中',
  p_deadline date default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_source text default '人工巡查',
  p_ai_analysis jsonb default null
)
returns public.inspection_records
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dictionary public.issue_dictionary%rowtype;
  v_department public.handling_departments%rowtype;
  v_grid public.unit_grids%rowtype;
  v_assignee public.profiles%rowtype;
  v_matter public.management_matters%rowtype;
  v_record public.inspection_records%rowtype;
  v_actor_id uuid := auth.uid();
  v_record_no text := trim(coalesce(p_record_no, ''));
  v_description text := trim(coalesce(p_description, ''));
  v_location text := trim(coalesce(p_location, ''));
  v_division_code text := trim(coalesce(p_administrative_division_code, ''));
  v_division_name text := nullif(trim(coalesce(p_administrative_division_name, '')), '');
  v_standard_ref text := trim(coalesce(p_standard_ref, ''));
  v_standard_code text := trim(coalesce(p_standard_code, ''));
  v_grid_identifier text := upper(trim(coalesce(p_grid_identifier, '')));
  v_owner_name text := trim(coalesce(p_owner_name, ''));
  v_source text := nullif(trim(coalesce(p_source, '')), '');
  v_status text := trim(coalesce(p_status, ''));
begin
  if v_actor_id is null then
    raise exception '登录状态已失效，请重新登录';
  end if;

  if not private.is_admin() then
    raise exception '只有管理员可以新建和派发案件';
  end if;

  if v_record_no = '' then
    raise exception '巡查编号不能为空';
  end if;
  if v_description = '' then
    raise exception '巡查问题不能为空';
  end if;
  if v_location = '' then
    raise exception '发现地点不能为空';
  end if;
  if v_division_code !~ '^[0-9]{6}$' then
    raise exception '行政区划代码必须为 6 位数字（GB/T 2260）';
  end if;
  if v_standard_ref = '' or v_standard_code !~ '^[0-9]{5}$' then
    raise exception '必须选择有效的 GB/T 47678.5-2026 管理事项';
  end if;
  if v_grid_identifier !~ '^[0-9A-Z]{15}$' then
    raise exception '必须选择有效的 15 位单元网格标识码';
  end if;
  if p_assignee_id is null or v_owner_name = '' then
    raise exception '必须选择在岗负责人';
  end if;
  if v_status not in ('待派单', '处理中') then
    raise exception '新建案件状态只能为待派单或处理中';
  end if;
  if v_status = '待派单' then
    raise exception '已选择负责人时，新建案件必须进入处理中';
  end if;

  select * into v_dictionary
  from public.issue_dictionary
  where standard_ref = v_standard_ref
    and matter_kind = '管理事项'
    and standard_code = v_standard_code
    and is_active = true;
  if not found then
    raise exception '未找到启用的国标管理事项：% / %', v_standard_ref, v_standard_code;
  end if;

  select * into v_department
  from public.handling_departments
  where department_label = v_dictionary.default_department
    and is_active = true;
  if not found then
    raise exception '请先配置“%”对应的处置主管部门和统一社会信用代码', v_dictionary.default_department;
  end if;

  select * into v_grid
  from public.unit_grids
  where grid_identifier = v_grid_identifier
    and administrative_division_code = v_division_code
    and is_active = true;
  if not found then
    raise exception '所选单元网格不存在、已停用，或不属于当前行政区划';
  end if;

  select * into v_assignee
  from public.profiles
  where id = p_assignee_id
    and is_active = true;
  if not found then
    raise exception '负责人账号不存在或已停用';
  end if;
  if trim(coalesce(v_assignee.display_name, '')) <> v_owner_name then
    raise exception '负责人姓名与所选账号不一致，请重新选择负责人';
  end if;

  insert into public.management_matters (
    standard_ref,
    matter_kind,
    matter_code,
    matter_type_code,
    matter_name,
    administrative_division_code,
    administrative_division_name,
    supervising_org_code,
    supervising_org_name,
    incident_location,
    grid_identifier,
    discovered_at,
    reported_at,
    source,
    longitude,
    latitude,
    coordinate_system,
    extension_attributes,
    updated_at
  ) values (
    v_dictionary.standard_ref,
    '管理事项',
    v_division_code || v_dictionary.standard_code,
    v_dictionary.standard_code,
    v_dictionary.standard_name,
    v_division_code,
    coalesce(v_division_name, v_grid.administrative_division_name),
    v_department.organization_code,
    v_department.organization_name,
    v_location,
    v_grid.grid_identifier,
    now(),
    now(),
    coalesce(v_source, '人工巡查'),
    p_longitude,
    p_latitude,
    'CGCS2000',
    '{}'::jsonb,
    now()
  ) returning * into v_matter;

  insert into public.inspection_records (
    record_no,
    description,
    location,
    administrative_division_code,
    administrative_division_name,
    supervising_org_code,
    supervising_org_name,
    grid_identifier,
    issue_type,
    standard_kind,
    standard_ref,
    standard_code,
    standard_name,
    department,
    priority,
    owner_name,
    assignee_id,
    status,
    deadline,
    latitude,
    longitude,
    source,
    ai_analysis,
    matter_id,
    created_by,
    updated_at
  ) values (
    v_record_no,
    v_description,
    v_location,
    v_division_code,
    coalesce(v_division_name, v_grid.administrative_division_name),
    v_department.organization_code,
    v_department.organization_name,
    v_grid.grid_identifier,
    v_dictionary.standard_name,
    '管理事项',
    v_dictionary.standard_ref,
    v_dictionary.standard_code,
    v_dictionary.standard_name,
    v_department.organization_name,
    v_dictionary.default_priority,
    v_assignee.display_name,
    v_assignee.id,
    v_status,
    p_deadline,
    p_latitude,
    p_longitude,
    coalesce(v_source, '人工巡查'),
    p_ai_analysis,
    v_matter.id,
    v_actor_id,
    now()
  ) returning * into v_record;

  insert into public.inspection_updates (
    record_id,
    actor_id,
    from_status,
    to_status,
    note
  ) values (
    v_record.id,
    v_actor_id,
    null,
    v_status,
    format('创建巡查记录并指派给负责人：%s', v_assignee.display_name)
  );

  return v_record;
end;
$$;

revoke all on function public.create_inspection_case_with_matter(
  text, text, text, text, text, text, text, text, uuid, text, text, date, numeric, numeric, text, jsonb
) from public;
grant execute on function public.create_inspection_case_with_matter(
  text, text, text, text, text, text, text, text, uuid, text, text, date, numeric, numeric, text, jsonb
) to authenticated;

comment on function public.create_inspection_case_with_matter is
  '管理员新建案件专用原子函数：校验国标事项、主管部门、单元网格、负责人后，同时创建管理事项实例、案件及首条处置时间线。';

commit;
