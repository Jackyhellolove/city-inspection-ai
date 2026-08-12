-- 负责人字段级保护。
-- 在 Supabase SQL Editor 运行一次，可重复执行。
-- 管理员可维护完整记录；被派单负责人只能修改处置状态和更新时间。

create or replace function public.protect_inspection_record_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
begin
  -- SQL Editor、迁移任务和 service_role 不带普通用户 JWT，由数据库管理流程负责。
  if current_user_id is null or private.is_admin() then
    return new;
  end if;

  if old.assignee_id is distinct from current_user_id then
    raise exception '只能处理分配给自己的巡查任务';
  end if;

  if new.status not in ('待派单', '处理中', '已完成') then
    raise exception '处置状态无效';
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
    raise exception '负责人只能修改处置状态、填写处理说明和上传整改凭证';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_inspection_record_fields_before_update
  on public.inspection_records;

create trigger protect_inspection_record_fields_before_update
before update on public.inspection_records
for each row execute function public.protect_inspection_record_fields();

create or replace function public.protect_inspection_record_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null and not private.is_admin() then
    raise exception '只有管理员可以删除巡查记录';
  end if;
  return old;
end;
$$;

drop trigger if exists protect_inspection_record_before_delete
  on public.inspection_records;

create trigger protect_inspection_record_before_delete
before delete on public.inspection_records
for each row execute function public.protect_inspection_record_delete();
