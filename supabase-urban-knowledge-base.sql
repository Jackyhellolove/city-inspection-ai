-- 城管国标事项知识库 V1.0
--
-- 前置：已执行 supabase-issue-dictionary.sql、supabase-issue-dictionary-v2.sql、
--       supabase-gb47678.5-directory.sql、supabase-ai-audit.sql。
--
-- 设计原则：issue_dictionary 仍是 GB/T 47678.5-2026 的唯一国标目录；
-- 本脚本只增加“可解释、可维护”的行业知识，不复制或篡改国标事项本体。
-- V1 覆盖：事项说明、同义词/地方叫法、正反视觉特征、易混淆事项、处置指引、匹配留痕。
-- 向量检索和大模型候选裁决将在积累真实复核样本后单独接入。

begin;

create table if not exists public.urban_issue_knowledge (
  id uuid primary key default gen_random_uuid(),
  standard_ref text not null default 'GB/T 47678.5-2026',
  matter_kind text not null default '管理事项' check (matter_kind = '管理事项'),
  standard_code varchar(5) not null check (standard_code ~ '^[0-9]{5}$'),
  knowledge_summary text not null default '',
  handling_guidance text not null default '',
  review_guidance text not null default '',
  is_high_frequency boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (standard_ref, matter_kind, standard_code),
  constraint urban_issue_knowledge_dictionary_fkey
    foreign key (standard_ref, matter_kind, standard_code)
    references public.issue_dictionary (standard_ref, matter_kind, standard_code)
    on delete cascade
);

alter table public.urban_issue_knowledge
  add column if not exists is_high_frequency boolean not null default false;

comment on table public.urban_issue_knowledge is
  '城管事项知识主体。关联 GB/T 47678.5-2026 管理事项，保存本地业务解释、处置指引和人工复核指引，不替代国标目录。';

create table if not exists public.urban_issue_knowledge_terms (
  id uuid primary key default gen_random_uuid(),
  knowledge_id uuid not null references public.urban_issue_knowledge(id) on delete cascade,
  term_type text not null check (term_type in ('同义词', '地方叫法', '关键词', '常见描述', '排除项')),
  term text not null check (length(trim(term)) between 2 and 120),
  administrative_division_code varchar(6) check (administrative_division_code is null or administrative_division_code ~ '^[0-9]{6}$'),
  weight numeric(4,3) not null default 0.800 check (weight >= 0 and weight <= 1),
  source_note text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists urban_issue_knowledge_terms_unique_idx
  on public.urban_issue_knowledge_terms (
    knowledge_id, term_type, term, coalesce(administrative_division_code, '')
  );
create index if not exists urban_issue_knowledge_terms_lookup_idx
  on public.urban_issue_knowledge_terms (knowledge_id, is_active, term_type);

comment on table public.urban_issue_knowledge_terms is
  '事项语义词库：同义词、地方叫法、关键词、常见描述和排除项。行政区划为空表示跨城市通用。';

create table if not exists public.urban_issue_visual_features (
  id uuid primary key default gen_random_uuid(),
  knowledge_id uuid not null references public.urban_issue_knowledge(id) on delete cascade,
  feature_type text not null check (feature_type in ('识别对象', '场景', '正向条件', '负向条件')),
  feature_text text not null check (length(trim(feature_text)) between 2 and 300),
  weight numeric(4,3) not null default 0.800 check (weight >= 0 and weight <= 1),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (knowledge_id, feature_type, feature_text)
);

comment on table public.urban_issue_visual_features is
  '供多模态模型/目标检测结果核验的视觉规则。正向条件支持推荐，负向条件用于降低或排除候选事项。';

create table if not exists public.urban_issue_confusions (
  id uuid primary key default gen_random_uuid(),
  knowledge_id uuid not null references public.urban_issue_knowledge(id) on delete cascade,
  confusing_standard_ref text not null default 'GB/T 47678.5-2026',
  confusing_matter_kind text not null default '管理事项' check (confusing_matter_kind = '管理事项'),
  confusing_standard_code varchar(5) not null check (confusing_standard_code ~ '^[0-9]{5}$'),
  distinction text not null check (length(trim(distinction)) between 2 and 1000),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (knowledge_id, confusing_standard_ref, confusing_matter_kind, confusing_standard_code),
  constraint urban_issue_confusions_dictionary_fkey
    foreign key (confusing_standard_ref, confusing_matter_kind, confusing_standard_code)
    references public.issue_dictionary (standard_ref, matter_kind, standard_code)
    on delete restrict
);

comment on table public.urban_issue_confusions is
  '事项易混淆关系及人工判别依据。用于候选排序解释和后续大模型裁决。';

create table if not exists public.urban_issue_match_logs (
  id uuid primary key default gen_random_uuid(),
  record_id uuid references public.inspection_records(id) on delete set null,
  ai_task_run_id uuid references public.ai_task_runs(id) on delete set null,
  source text not null check (source in ('照片AI', '文字录入', '人工选择')),
  input_summary text not null default '',
  candidate_matches jsonb not null default '[]'::jsonb
    check (jsonb_typeof(candidate_matches) = 'array'),
  recommended_knowledge_id uuid references public.urban_issue_knowledge(id) on delete set null,
  recommended_standard_code varchar(5) check (recommended_standard_code is null or recommended_standard_code ~ '^[0-9]{5}$'),
  recommendation_methods text[] not null default array[]::text[],
  recommendation_confidence numeric(4,3) check (recommendation_confidence is null or (recommendation_confidence >= 0 and recommendation_confidence <= 1)),
  review_status text not null default '待确认' check (review_status in ('待确认', '已确认', '已修正', '已驳回')),
  confirmed_knowledge_id uuid references public.urban_issue_knowledge(id) on delete set null,
  correction_reason text not null default '',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists urban_issue_match_logs_record_idx
  on public.urban_issue_match_logs (record_id, created_at desc) where record_id is not null;
create index if not exists urban_issue_match_logs_status_idx
  on public.urban_issue_match_logs (review_status, created_at desc);
create index if not exists urban_issue_match_logs_recommendation_idx
  on public.urban_issue_match_logs (recommended_standard_code, created_at desc)
  where recommended_standard_code is not null;

comment on table public.urban_issue_match_logs is
  '国标智能匹配留痕。保存脱敏文字摘要、候选事项、匹配方式、置信度和人工确认/修正结果；不保存图片 Base64、令牌或 API 密钥。';

-- 为已导入的所有国标管理事项建立知识主体；已有人工编辑内容不覆盖。
insert into public.urban_issue_knowledge (standard_ref, matter_kind, standard_code)
select standard_ref, matter_kind, standard_code
from public.issue_dictionary
where matter_kind = '管理事项'
  and is_active = true
on conflict (standard_ref, matter_kind, standard_code) do nothing;

-- 250 条事项仅保留知识主体“空壳”。本阶段只建设下列 10 条高频事项，避免用未经真实样本验证的词语污染其余事项。
update public.urban_issue_knowledge
set is_high_frequency = false,
    updated_at = now();

update public.urban_issue_knowledge
set is_high_frequency = true,
    updated_at = now()
where standard_ref = 'GB/T 47678.5-2026'
  and matter_kind = '管理事项'
  and standard_code in ('06010', '06011', '06012', '06017', '06036', '06042', '06045', '07003', '09005', '09006');

-- 若曾执行过早期草案，清除非高频事项的自动基础词；管理员手工维护的数据不受影响。
delete from public.urban_issue_knowledge_terms terms
using public.urban_issue_knowledge knowledge
where terms.knowledge_id = knowledge.id
  and knowledge.is_high_frequency = false
  and terms.source_note in ('国标正式名称', '标准问题字典关键词');

-- 以 06042“垃圾站（箱）满溢”作为首个可用知识样例。
update public.urban_issue_knowledge
set knowledge_summary = '垃圾收集容器内垃圾超过容纳能力或桶口，且可见桶外散落、堆积或外溢垃圾。',
    handling_guidance = '优先组织清运并清扫桶周及人行道；核查容器配置和清运频次，必要时增配容器或调整路线。',
    review_guidance = '容器完整且垃圾超过桶口、桶外有散落垃圾时优先判为满溢；仅有路面暴露垃圾、无关联容器时应审慎与“暴露垃圾”区分。',
    updated_at = now()
where standard_ref = 'GB/T 47678.5-2026'
  and matter_kind = '管理事项'
  and standard_code = '06042';

-- 其余 9 条高频事项的业务解释、处置重点和人工判别边界。
update public.urban_issue_knowledge knowledge
set knowledge_summary = seed.knowledge_summary,
    handling_guidance = seed.handling_guidance,
    review_guidance = seed.review_guidance,
    updated_at = now()
from (values
  ('06010', '暴露在道路、绿地或公共空间的生活垃圾，核心是垃圾裸露、无完整收集容器承接。', '及时清扫、收集和转运；同步排查附近投放点、清运频次和反复倾倒点位。', '有完整垃圾桶/箱且垃圾超出桶口时优先判“垃圾站（箱）满溢”；大量长期堆积或混有渣土时与“积存垃圾渣土”区分。'),
  ('06011', '公共区域出现成片、成堆或长期积存的垃圾、渣土，核心是堆积规模和滞留状态。', '组织清运、清扫和分类处置；对反复点位核查责任主体、清运机制和源头管理。', '短时零散裸露垃圾通常判“暴露垃圾”；有明确垃圾桶/箱超容事实时优先判“垃圾站（箱）满溢”。'),
  ('06012', '道路表面存在尘土、污渍、油污或其他不洁状态，影响市容和通行环境。', '安排道路清扫、冲洗或吸污；油污等可能影响安全时应先采取警示和防滑措施。', '车辆或施工造成的抛撒、遗撒应与“道路遗撒（洒）”区分；单纯道路破损不归入本事项。'),
  ('06017', '绿地、绿化带内及周边存在散落垃圾、杂物或卫生脏乱，核心是绿地环境不整洁。', '清理绿地及绿化带垃圾，恢复保洁；核查周边投放点、保洁频次和巡查责任。', '出现侵占、硬化、挖掘或植物毁损等行为时，应优先考虑“非法占绿毁绿”。'),
  ('06036', '道路、人行道等公共区域存在非施工性质的杂物或物料无序堆放，影响通行和市容。', '督促责任人清理并恢复通行空间；无法明确责任人时组织先行清运并保留现场记录。', '有明确施工现场、施工材料和施工主体时，应考虑“施工物料乱堆放”；经营商品外摆则与“店外经营”区分。'),
  ('06045', '存在占用、挖掘、硬化、踩踏等造成绿地或绿化带被侵占、损坏的事实。', '立即制止侵占或破坏行为，保护现场；组织恢复绿化并依法核查责任主体。', '仅有绿地垃圾、落叶或保洁不到位时，优先判“绿地脏乱”，不应误判为毁绿。'),
  ('07003', '未经许可或不符合规定设置的户外广告设施、广告画面或广告载体。', '核验设置许可、位置、安全和内容要求；对存在安全风险的广告设施优先处置。', '张贴、喷涂等小型非法广告优先考虑“非法小广告”；仅牌匾标识不规范时与“违规牌匾标识”区分。'),
  ('09005', '固定商户将商品、桌椅、设备或经营活动延伸至店铺门外，影响市容或通行秩序。', '督促商户撤回店外经营物品、恢复门前秩序；对反复行为纳入重点巡查。', '无固定店铺的流动摊贩占用道路时，优先考虑“占道经营”。'),
  ('09006', '流动或固定摊贩在道路、人行道等公共通行空间摆卖、经营，影响通行和街面秩序。', '依法劝导、规范或清理占道经营，兼顾人行通道和消防通道畅通。', '有明确临街商铺且经营物品从店内外摆时，优先考虑“店外经营”。')
) as seed(standard_code, knowledge_summary, handling_guidance, review_guidance)
where knowledge.standard_ref = 'GB/T 47678.5-2026'
  and knowledge.matter_kind = '管理事项'
  and knowledge.standard_code = seed.standard_code;

insert into public.urban_issue_knowledge_terms (
  knowledge_id, term_type, term, weight, source_note
)
select knowledge.id, seed.term_type, seed.term, seed.weight, 'V1 预置：经人工核对的通用城管表述'
from public.urban_issue_knowledge knowledge
cross join (values
  ('同义词', '垃圾桶满溢', 0.980::numeric),
  ('同义词', '垃圾箱满溢', 0.980::numeric),
  ('同义词', '垃圾桶爆满', 0.960::numeric),
  ('同义词', '垃圾箱爆满', 0.960::numeric),
  ('同义词', '垃圾外溢', 0.880::numeric),
  ('常见描述', '垃圾超过桶口', 0.920::numeric),
  ('常见描述', '垃圾袋散落在垃圾桶周围', 0.900::numeric),
  ('常见描述', '垃圾未及时清运造成桶边堆积', 0.860::numeric),
  ('关键词', '垃圾桶', 0.500::numeric),
  ('关键词', '垃圾箱', 0.500::numeric),
  ('关键词', '满溢', 0.800::numeric),
  ('关键词', '外溢', 0.760::numeric),
  ('排除项', '垃圾桶破损', 0.900::numeric),
  ('排除项', '垃圾未分类', 0.900::numeric)
) as seed(term_type, term, weight)
where knowledge.standard_ref = 'GB/T 47678.5-2026'
  and knowledge.matter_kind = '管理事项'
  and knowledge.standard_code = '06042'
on conflict do nothing;

-- 高发事项语义词。词条仅用于“推荐候选”，所有案件仍须人工确认国标事项后保存。
insert into public.urban_issue_knowledge_terms (
  knowledge_id, term_type, term, weight, source_note
)
select knowledge.id, seed.term_type, seed.term, seed.weight, '高频十项 V1：待真实照片复核持续校正'
from public.urban_issue_knowledge knowledge
join (values
  ('06010', '同义词', '随意倾倒垃圾', 0.940::numeric), ('06010', '同义词', '路边垃圾', 0.820::numeric), ('06010', '常见描述', '地面散落生活垃圾', 0.900::numeric), ('06010', '关键词', '裸露垃圾', 0.900::numeric), ('06010', '排除项', '垃圾桶满溢', 0.950::numeric),
  ('06011', '同义词', '乱倒垃圾', 0.900::numeric), ('06011', '同义词', '积存垃圾', 0.940::numeric), ('06011', '常见描述', '垃圾长期堆积', 0.900::numeric), ('06011', '常见描述', '渣土堆放', 0.880::numeric), ('06011', '排除项', '垃圾桶满溢', 0.950::numeric),
  ('06012', '同义词', '道路污染', 0.940::numeric), ('06012', '同义词', '路面污染', 0.920::numeric), ('06012', '同义词', '道路脏污', 0.880::numeric), ('06012', '关键词', '路面积尘', 0.820::numeric), ('06012', '关键词', '路面油污', 0.860::numeric),
  ('06017', '同义词', '绿化带垃圾', 0.960::numeric), ('06017', '同义词', '绿地垃圾', 0.940::numeric), ('06017', '同义词', '绿化带脏乱', 0.900::numeric), ('06017', '常见描述', '绿地内散落垃圾', 0.920::numeric), ('06017', '排除项', '破坏绿化带', 0.920::numeric),
  ('06036', '同义词', '乱堆物料', 0.940::numeric), ('06036', '同义词', '乱堆杂物', 0.980::numeric), ('06036', '同义词', '公共区域堆物', 0.900::numeric), ('06036', '常见描述', '路边堆放杂物', 0.860::numeric), ('06036', '排除项', '施工材料', 0.860::numeric),
  ('06045', '同义词', '绿地破坏', 0.960::numeric), ('06045', '同义词', '毁绿', 0.940::numeric), ('06045', '同义词', '占绿', 0.900::numeric), ('06045', '常见描述', '破坏绿化带', 0.920::numeric), ('06045', '排除项', '绿地垃圾', 0.860::numeric),
  ('07003', '同义词', '违规广告', 0.960::numeric), ('07003', '同义词', '违规户外广告', 0.980::numeric), ('07003', '同义词', '违法广告牌', 0.900::numeric), ('07003', '常见描述', '违规设置广告牌', 0.880::numeric), ('07003', '排除项', '小广告', 0.850::numeric),
  ('09005', '同义词', '店外经营', 0.980::numeric), ('09005', '同义词', '出店经营', 0.950::numeric), ('09005', '同义词', '门店外摆', 0.900::numeric), ('09005', '常见描述', '店铺外摆货物', 0.900::numeric), ('09005', '排除项', '流动摊贩占道', 0.850::numeric),
  ('09006', '同义词', '占道经营', 0.980::numeric), ('09006', '同义词', '路边摆摊', 0.940::numeric), ('09006', '同义词', '占道摆卖', 0.940::numeric), ('09006', '同义词', '人行道摆摊', 0.900::numeric), ('09006', '排除项', '店外摆货物', 0.850::numeric)
) as seed(standard_code, term_type, term, weight)
  on knowledge.standard_ref = 'GB/T 47678.5-2026'
 and knowledge.matter_kind = '管理事项'
 and knowledge.standard_code = seed.standard_code
on conflict do nothing;

insert into public.urban_issue_visual_features (
  knowledge_id, feature_type, feature_text, weight
)
select knowledge.id, seed.feature_type, seed.feature_text, seed.weight
from public.urban_issue_knowledge knowledge
cross join (values
  ('识别对象', '垃圾桶、垃圾箱或垃圾收集容器', 0.700::numeric),
  ('识别对象', '生活垃圾袋、散落垃圾', 0.650::numeric),
  ('场景', '道路、人行道、公共区域的收集容器周边', 0.550::numeric),
  ('正向条件', '垃圾高度超过桶口或容器容量', 0.980::numeric),
  ('正向条件', '桶外可见散落或堆积垃圾', 0.820::numeric),
  ('负向条件', '容器本体破损、倾斜、缺失为主要问题', 0.850::numeric),
  ('负向条件', '主要问题是垃圾分类投放错误而非容量满溢', 0.850::numeric)
) as seed(feature_type, feature_text, weight)
where knowledge.standard_ref = 'GB/T 47678.5-2026'
  and knowledge.matter_kind = '管理事项'
  and knowledge.standard_code = '06042'
on conflict do nothing;

insert into public.urban_issue_visual_features (
  knowledge_id, feature_type, feature_text, weight
)
select knowledge.id, seed.feature_type, seed.feature_text, seed.weight
from public.urban_issue_knowledge knowledge
join (values
  ('06010', '识别对象', '散落的生活垃圾袋、纸屑或垃圾堆', 0.760::numeric), ('06010', '场景', '道路、人行道、绿地等无容器公共空间', 0.760::numeric), ('06010', '负向条件', '垃圾明确从完整垃圾桶或垃圾箱外溢', 0.900::numeric),
  ('06011', '识别对象', '成片堆积垃圾、渣土或混合废弃物', 0.780::numeric), ('06011', '场景', '长期堆放点、空地或道路边角', 0.720::numeric), ('06011', '正向条件', '垃圾堆体量明显、堆积而非零散散落', 0.900::numeric),
  ('06012', '识别对象', '尘土、泥浆、油污或大面积污渍', 0.740::numeric), ('06012', '场景', '机动车道、人行道或路面', 0.780::numeric), ('06012', '正向条件', '路面大面积不洁或污染影响市容通行', 0.880::numeric),
  ('06017', '识别对象', '绿化带或绿地内散落垃圾、杂物', 0.780::numeric), ('06017', '场景', '草坪、绿化带、树池等绿地范围', 0.860::numeric), ('06017', '正向条件', '绿地保洁不到位且未见明显毁损行为', 0.850::numeric),
  ('06036', '识别对象', '杂物、箱体、废旧物品或非施工物料', 0.720::numeric), ('06036', '场景', '公共通道、道路边或人行道', 0.780::numeric), ('06036', '正向条件', '物品无序堆放并妨碍市容或通行', 0.880::numeric),
  ('06045', '识别对象', '被占用、硬化、开挖或明显损坏的绿地', 0.820::numeric), ('06045', '场景', '草坪、绿化带、树池等绿地范围', 0.820::numeric), ('06045', '正向条件', '存在侵占或损毁绿化的可见事实', 0.920::numeric),
  ('07003', '识别对象', '大型广告牌、户外广告画面或广告设施', 0.780::numeric), ('07003', '场景', '建筑立面、道路沿线或公共设施表面', 0.700::numeric), ('07003', '正向条件', '广告设置位置、形式或体量疑似违规', 0.700::numeric),
  ('09005', '识别对象', '店铺门前外摆的货物、桌椅或经营设备', 0.780::numeric), ('09005', '场景', '固定临街商铺门前', 0.900::numeric), ('09005', '正向条件', '经营活动从店内延伸至店外公共空间', 0.900::numeric),
  ('09006', '识别对象', '摊位、售卖车、摆卖商品或流动摊贩', 0.780::numeric), ('09006', '场景', '道路、人行道、路口等公共通行空间', 0.860::numeric), ('09006', '正向条件', '摊贩摆卖占用公共道路或人行通道', 0.920::numeric)
) as seed(standard_code, feature_type, feature_text, weight)
  on knowledge.standard_ref = 'GB/T 47678.5-2026'
 and knowledge.matter_kind = '管理事项'
 and knowledge.standard_code = seed.standard_code
on conflict do nothing;

insert into public.urban_issue_confusions (
  knowledge_id, confusing_standard_ref, confusing_matter_kind, confusing_standard_code, distinction
)
select knowledge.id, 'GB/T 47678.5-2026', '管理事项', seed.standard_code, seed.distinction
from public.urban_issue_knowledge knowledge
cross join (values
  ('06010', '“暴露垃圾”侧重无容器关联的裸露垃圾；存在完整垃圾桶/箱且垃圾超出容器容量时，优先判为“垃圾站（箱）满溢”。'),
  ('06011', '“积存垃圾渣土”侧重大量长期堆放垃圾或渣土；以垃圾收集容器超容、桶边外溢为核心事实时，优先判为“垃圾站（箱）满溢”。'),
  ('06041', '“垃圾未分类”侧重投放分类错误；只有分类标识或投放类别错误、无明显满溢时才考虑该事项。')
) as seed(standard_code, distinction)
where knowledge.standard_ref = 'GB/T 47678.5-2026'
  and knowledge.matter_kind = '管理事项'
  and knowledge.standard_code = '06042'
on conflict do nothing;

insert into public.urban_issue_confusions (
  knowledge_id, confusing_standard_ref, confusing_matter_kind, confusing_standard_code, distinction
)
select knowledge.id, 'GB/T 47678.5-2026', '管理事项', seed.confusing_standard_code, seed.distinction
from public.urban_issue_knowledge knowledge
join (values
  ('06010', '06011', '零散、短时且无容器关联的裸露垃圾优先判“暴露垃圾”；成片、长期堆积或混有渣土时优先判“积存垃圾渣土”。'),
  ('06010', '06042', '有完整垃圾桶/箱并发生超容外溢时优先判“垃圾站（箱）满溢”，而非“暴露垃圾”。'),
  ('06011', '06042', '垃圾桶/箱超容是“满溢”；无明确容器、以大堆积垃圾或渣土为主时判“积存垃圾渣土”。'),
  ('06012', '06014', '车辆、施工造成的明确抛撒或遗撒优先判“道路遗撒（洒）”；一般尘土、污渍和油污导致的不洁判“道路不洁”。'),
  ('06017', '06045', '绿地内垃圾、保洁不到位判“绿地脏乱”；侵占、硬化、开挖或植物毁损判“非法占绿毁绿”。'),
  ('06036', '08006', '有施工现场和施工材料的乱堆放，优先判“施工物料乱堆放”；普通公共区域杂物堆放判“乱堆杂物”。'),
  ('07003', '07001', '张贴、喷涂、刻画等小型非法广告判“非法小广告”；独立户外广告设施或广告牌疑似违规判“违规户外广告”。'),
  ('09005', '09006', '经营主体明确为临街固定商铺且物品外摆判“店外经营”；流动摊贩在通道摆卖判“占道经营”。'),
  ('09006', '09005', '流动摊位、摆卖车等占用道路判“占道经营”；固定商铺将商品或桌椅摆出店门判“店外经营”。')
) as seed(standard_code, confusing_standard_code, distinction)
  on knowledge.standard_ref = 'GB/T 47678.5-2026'
 and knowledge.matter_kind = '管理事项'
 and knowledge.standard_code = seed.standard_code
on conflict do nothing;

-- 照片 AI 的真实验收口径：只统计已由人工确认或修正的“照片AI”匹配记录。
-- 准确率=推荐五位代码与人工最终确认五位代码一致的比例；至少 50 张且每个高频事项至少 5 张后，才可宣称达到 80% 目标。
create or replace view public.urban_issue_photo_match_evaluation_v
with (security_invoker = true)
as
select logs.id,
       logs.created_at,
       logs.record_id,
       logs.recommended_standard_code,
       confirmed.standard_code as confirmed_standard_code,
       logs.recommendation_confidence,
       logs.review_status,
       confirmed.is_high_frequency,
       case
         when logs.review_status in ('已确认', '已修正')
          and confirmed.standard_code is not null
         then logs.recommended_standard_code = confirmed.standard_code
         else null
       end as is_correct
from public.urban_issue_match_logs logs
left join public.urban_issue_knowledge confirmed on confirmed.id = logs.confirmed_knowledge_id
where logs.source = '照片AI';

comment on view public.urban_issue_photo_match_evaluation_v is
  '照片AI国标匹配验收视图。仅人工复核后计入准确率，不能用AI自评或文字样例替代真实照片测试。';

alter table public.urban_issue_knowledge enable row level security;
alter table public.urban_issue_knowledge_terms enable row level security;
alter table public.urban_issue_visual_features enable row level security;
alter table public.urban_issue_confusions enable row level security;
alter table public.urban_issue_match_logs enable row level security;

drop policy if exists "authenticated users read urban issue knowledge" on public.urban_issue_knowledge;
create policy "authenticated users read urban issue knowledge"
  on public.urban_issue_knowledge for select to authenticated using (is_active);
drop policy if exists "admins manage urban issue knowledge" on public.urban_issue_knowledge;
create policy "admins manage urban issue knowledge"
  on public.urban_issue_knowledge for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "authenticated users read urban issue knowledge terms" on public.urban_issue_knowledge_terms;
create policy "authenticated users read urban issue knowledge terms"
  on public.urban_issue_knowledge_terms for select to authenticated using (is_active);
drop policy if exists "admins manage urban issue knowledge terms" on public.urban_issue_knowledge_terms;
create policy "admins manage urban issue knowledge terms"
  on public.urban_issue_knowledge_terms for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "authenticated users read urban issue visual features" on public.urban_issue_visual_features;
create policy "authenticated users read urban issue visual features"
  on public.urban_issue_visual_features for select to authenticated using (is_active);
drop policy if exists "admins manage urban issue visual features" on public.urban_issue_visual_features;
create policy "admins manage urban issue visual features"
  on public.urban_issue_visual_features for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "authenticated users read urban issue confusions" on public.urban_issue_confusions;
create policy "authenticated users read urban issue confusions"
  on public.urban_issue_confusions for select to authenticated using (is_active);
drop policy if exists "admins manage urban issue confusions" on public.urban_issue_confusions;
create policy "admins manage urban issue confusions"
  on public.urban_issue_confusions for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "admins read urban issue match logs" on public.urban_issue_match_logs;
create policy "admins read urban issue match logs"
  on public.urban_issue_match_logs for select to authenticated
  using (private.is_admin());
drop policy if exists "users read own urban issue match logs" on public.urban_issue_match_logs;
create policy "users read own urban issue match logs"
  on public.urban_issue_match_logs for select to authenticated
  using (created_by = auth.uid());
drop policy if exists "users append own urban issue match logs" on public.urban_issue_match_logs;
create policy "users append own urban issue match logs"
  on public.urban_issue_match_logs for insert to authenticated
  with check (created_by = auth.uid());
drop policy if exists "admins update urban issue match logs" on public.urban_issue_match_logs;
create policy "admins update urban issue match logs"
  on public.urban_issue_match_logs for update to authenticated
  using (private.is_admin()) with check (private.is_admin());

commit;
