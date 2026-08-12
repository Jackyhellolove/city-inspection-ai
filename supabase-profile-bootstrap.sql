-- 注册账号与人员资料同步。
-- 解决以下问题：
-- 1. auth.users 已存在，但 public.profiles 缺失；
-- 2. 未验证邮箱过早出现在负责人派单名单。
-- 可重复执行。

alter table public.profiles
  add column if not exists department text,
  add column if not exists is_active boolean not null default false;

create or replace function public.sync_profile_from_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role, department, is_active)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1)),
    'inspector',
    null,
    new.email_confirmed_at is not null
  )
  on conflict (id) do update
  set is_active = case
    when new.email_confirmed_at is not null then true
    else public.profiles.is_active
  end;
  return new;
end;
$$;

drop trigger if exists sync_profile_after_auth_user_change on auth.users;
create trigger sync_profile_after_auth_user_change
after insert or update of email_confirmed_at on auth.users
for each row execute function public.sync_profile_from_auth_user();

-- 补齐已确认、但没有 profiles 资料的历史账号。
insert into public.profiles (id, display_name, role, department, is_active)
select
  auth_user.id,
  coalesce(nullif(trim(auth_user.raw_user_meta_data ->> 'display_name'), ''), split_part(auth_user.email, '@', 1)),
  'inspector',
  null,
  true
from auth.users auth_user
left join public.profiles profile on profile.id = auth_user.id
where profile.id is null
  and auth_user.email_confirmed_at is not null
on conflict (id) do nothing;

-- 未验证且从未登录的账号不进入负责人名单；管理员确认前仍可在 Auth 用户列表处理。
update public.profiles profile
set is_active = false
from auth.users auth_user
where profile.id = auth_user.id
  and auth_user.email_confirmed_at is null
  and auth_user.last_sign_in_at is null;
