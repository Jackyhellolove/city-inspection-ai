-- 在 Supabase SQL Editor 中运行一次，启用巡查记录的实时同步。
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'inspection_records'
  ) then
    execute 'alter publication supabase_realtime add table public.inspection_records';
  end if;
end;
$$;
