-- 处置闭环 V2：在 Supabase SQL Editor 中运行一次，可重复执行。
-- 新流程：待派单 → 待接单 → 处理中 → 待核查 → 已结案。
-- 管理员可在待核查时退回整改；负责人只能推进自己的案件。

-- 先替换旧状态约束。旧约束只允许“待派单、处理中、已完成”，
-- 若不先移除，历史数据无法迁移为“已结案”。
alter table public.inspection_records
  drop constraint if exists inspection_records_status_check;

-- 历史“已完成”记录统一显示为“已结案”。
update public.inspection_records
set status = '已结案', updated_at = now()
where status = '已完成';

alter table public.inspection_records
  add constraint inspection_records_status_check
  check (status in ('待派单', '待接单', '处理中', '待核查', '退回整改', '已结案'));

create or replace function public.protect_inspection_record_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  allowed_statuses text[];
begin
  -- SQL Editor、迁移任务和 service_role 不带普通用户 JWT，由数据库管理流程负责。
  if current_user_id is null then
    return new;
  end if;

  if new.status not in ('待派单', '待接单', '处理中', '待核查', '退回整改', '已结案') then
    raise exception '处置状态无效';
  end if;

  if private.is_admin() then
    -- 管理员不允许无负责人案件跳过派单；结案必须来自核查节点。
    if new.assignee_id is null and new.status <> '待派单' then
      raise exception '请先指定负责人后再推进案件';
    end if;
    if old.status is distinct from new.status then
      case old.status
        when '待派单' then allowed_statuses := array['待派单', '待接单'];
        when '待接单' then allowed_statuses := array['待接单', '退回整改'];
        when '处理中' then allowed_statuses := array['处理中', '退回整改'];
        when '待核查' then allowed_statuses := array['待核查', '已结案', '退回整改'];
        when '退回整改' then allowed_statuses := array['退回整改', '处理中'];
        when '已结案' then allowed_statuses := array['已结案', '退回整改'];
        else allowed_statuses := array['待派单'];
      end case;
      if not (new.status = any(allowed_statuses)) then
        raise exception '管理员不能跳过处置流程节点';
      end if;
    end if;
    return new;
  end if;

  if old.assignee_id is distinct from current_user_id then
    raise exception '只能处理分配给自己的巡查任务';
  end if;

  if new.record_no is distinct from old.record_no
    or new.description is distinct from old.description
    or new.location is distinct from old.location
    or new.issue_type is distinct from old.issue_type
    or new.department is distinct from old.department
    or new.priority is distinct from old.priority
    or new.owner_name is distinct from old.owner_name
    or new.assignee_id is distinct from old.assignee_id
    or new.deadline is distinct from old.deadline
    or new.latitude is distinct from old.latitude
    or new.longitude is distinct from old.longitude
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or new.photo_path is distinct from old.photo_path
    or new.ai_analysis is distinct from old.ai_analysis
  then
    raise exception '负责人只能修改自己的处置状态、填写处理说明和上传整改凭证';
  end if;

  if old.status = '待接单' and new.status not in ('待接单', '处理中') then
    raise exception '请先接单，再开始处理';
  end if;
  if old.status in ('处理中', '退回整改') and new.status not in (old.status, '待核查') then
    raise exception '负责人处理完成后只能提交核查';
  end if;
  if old.status not in ('待接单', '处理中', '退回整改') and new.status is distinct from old.status then
    raise exception '当前节点不允许负责人修改状态';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_inspection_record_fields_before_update
  on public.inspection_records;

create trigger protect_inspection_record_fields_before_update
before update on public.inspection_records
for each row execute function public.protect_inspection_record_fields();
