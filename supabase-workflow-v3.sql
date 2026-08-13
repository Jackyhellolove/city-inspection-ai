-- 处置闭环 V3：在 Supabase SQL Editor 中完整执行一次，可重复执行。
--
-- 固定业务流程：
-- 管理员新建并指派 → 负责人办理 → 管理员核查 → 已结案 / 退回整改。
-- “退回整改”由负责人重新办理后回到“待核查”。
-- 该脚本同时在数据库层限制越权和跳过节点的接口请求。

begin;

-- 移除旧流程中的“待接单”；历史状态统一迁移。
alter table public.inspection_records
  drop constraint if exists inspection_records_status_check;

update public.inspection_records
set status = case
  when status = '已完成' then '已结案'
  when status = '待接单' then '处理中'
  else status
end,
updated_at = now()
where status in ('已完成', '待接单');

alter table public.inspection_records
  add constraint inspection_records_status_check
  check (status in ('待派单', '处理中', '待核查', '退回整改', '已结案'));

-- 管理员负责新建、派单、核查和办结；负责人只能推进本人案件。
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

  if new.status not in ('待派单', '处理中', '待核查', '退回整改', '已结案') then
    raise exception '处置状态无效';
  end if;

  if tg_op = 'INSERT' then
    if not private.is_admin() then
      raise exception '只有管理员可以新建和派发案件';
    end if;
    if new.status = '待派单' and new.assignee_id is not null then
      raise exception '已选择负责人时，案件必须进入处理中';
    end if;
    if new.status = '处理中' and new.assignee_id is null then
      raise exception '请先选择负责人后再提交案件';
    end if;
    if new.status not in ('待派单', '处理中') then
      raise exception '新建案件只能为待派单或处理中';
    end if;
    return new;
  end if;

  if private.is_admin() then
    -- 已指派案件不得清空负责人；管理员只可在待核查阶段给出结论。
    if new.assignee_id is null and new.status <> '待派单' then
      raise exception '请先指定负责人后再推进案件';
    end if;
    if old.status is distinct from new.status then
      case old.status
        when '待派单' then allowed_statuses := array['待派单', '处理中'];
        when '处理中' then allowed_statuses := array['处理中'];
        when '待核查' then allowed_statuses := array['待核查', '已结案', '退回整改'];
        when '退回整改' then allowed_statuses := array['退回整改'];
        when '已结案' then allowed_statuses := array['已结案'];
        else allowed_statuses := array[old.status];
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

  -- 负责人不能变更案件基础字段、负责人、期限、AI 结论或现场原始照片。
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
    raise exception '负责人只能填写处理说明、上传凭证并推进本人案件';
  end if;

  if old.status in ('处理中', '退回整改')
    and new.status not in (old.status, '待核查') then
    raise exception '负责人办理完成后只能提交管理员核查';
  end if;
  if old.status not in ('处理中', '退回整改')
    and new.status is distinct from old.status then
    raise exception '当前节点不允许负责人修改状态';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_inspection_record_fields_before_insert_or_update
  on public.inspection_records;
drop trigger if exists protect_inspection_record_fields_before_update
  on public.inspection_records;

create trigger protect_inspection_record_fields_before_insert_or_update
before insert or update on public.inspection_records
for each row execute function public.protect_inspection_record_fields();

-- 负责人只能读取、新增本人案件的处理过程与整改附件；管理员可核查全部。
drop policy if exists "为有权限巡查记录新增处置过程" on public.inspection_updates;
create policy "为有权限巡查记录新增处置过程"
on public.inspection_updates for insert to authenticated
with check (
  actor_id = (select auth.uid())
  and exists (
    select 1 from public.inspection_records record
    where record.id = inspection_updates.record_id
      and (record.assignee_id = (select auth.uid()) or (select private.is_admin()))
  )
);

drop policy if exists "为有权限记录新增整改附件" on public.inspection_attachments;
create policy "为有权限记录新增整改附件"
on public.inspection_attachments for insert to authenticated
with check (
  uploaded_by = (select auth.uid())
  and exists (
    select 1 from public.inspection_records record
    where record.id = inspection_attachments.record_id
      and (record.assignee_id = (select auth.uid()) or (select private.is_admin()))
  )
);

commit;

-- 执行后核对：只应有五种状态。
select status as "状态", count(*) as "案件数"
from public.inspection_records
group by status
order by status;
