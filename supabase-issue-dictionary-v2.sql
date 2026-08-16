-- 修复 GB/T 47678.5-2026 正式目录的唯一键
-- 管理部件（附录 A）与管理事项（附录 C）都采用“大类 2 位 + 小类 3 位”的五位分类码，
-- 例如两类中都可能有 01001，因此唯一性必须包含 matter_kind。
-- 在已执行 supabase-issue-dictionary.sql 的项目中，先执行本脚本，再执行全量目录导入脚本。

begin;

alter table public.issue_dictionary
  drop constraint if exists issue_dictionary_standard_ref_standard_code_key;

alter table public.issue_dictionary
  alter column standard_code set not null;

alter table public.issue_dictionary
  drop constraint if exists issue_dictionary_standard_ref_matter_kind_standard_code_key;

alter table public.issue_dictionary
  add constraint issue_dictionary_standard_ref_matter_kind_standard_code_key
  unique (standard_ref, matter_kind, standard_code);

commit;
