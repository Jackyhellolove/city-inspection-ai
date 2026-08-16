-- 城管知识库高频十项验收检查（只读）
-- 前置：已执行 supabase-urban-knowledge-base.sql，并完成真实照片 AI 识别和人工确认。
-- 不能用文字描述样例或模型自评替代真实照片验收。

-- 1. 检查 10 个高频事项的知识包是否齐全：每项至少 1 条说明、3 个语义词、3 个视觉特征。
with high_frequency as (
  select * from (values
    ('06010', '暴露垃圾'), ('06011', '积存垃圾渣土（乱倒垃圾）'), ('06012', '道路不洁（道路污染）'),
    ('06017', '绿地脏乱（绿化带垃圾）'), ('06036', '乱堆杂物（乱堆物料）'), ('06042', '垃圾站（箱）满溢'),
    ('06045', '非法占绿毁绿（绿地破坏）'), ('07003', '违规户外广告'), ('09005', '店外经营'), ('09006', '占道经营')
  ) as item(standard_code, standard_name)
), coverage as (
  select item.standard_code,
         item.standard_name,
         knowledge.id,
         knowledge.knowledge_summary,
         count(distinct terms.id) filter (where terms.is_active) as term_count,
         count(distinct features.id) filter (where features.is_active) as visual_feature_count
  from high_frequency item
  left join public.urban_issue_knowledge knowledge
    on knowledge.standard_ref = 'GB/T 47678.5-2026'
   and knowledge.matter_kind = '管理事项'
   and knowledge.standard_code = item.standard_code
  left join public.urban_issue_knowledge_terms terms on terms.knowledge_id = knowledge.id
  left join public.urban_issue_visual_features features on features.knowledge_id = knowledge.id
  group by item.standard_code, item.standard_name, knowledge.id, knowledge.knowledge_summary
)
select standard_code as "国标代码",
       standard_name as "高频事项",
       length(trim(coalesce(knowledge_summary, ''))) > 0 as "有业务解释",
       term_count as "语义词数",
       visual_feature_count as "视觉特征数",
       case when length(trim(coalesce(knowledge_summary, ''))) > 0 and term_count >= 3 and visual_feature_count >= 3
         then '可进入真实照片测试'
         else '知识包待补充'
       end as "状态"
from coverage
order by standard_code;

-- 2. 按事项查看照片 AI 的人工复核结果。每项至少应有 5 张真实照片。
with high_frequency as (
  select * from (values
    ('06010', '暴露垃圾'), ('06011', '积存垃圾渣土（乱倒垃圾）'), ('06012', '道路不洁（道路污染）'),
    ('06017', '绿地脏乱（绿化带垃圾）'), ('06036', '乱堆杂物（乱堆物料）'), ('06042', '垃圾站（箱）满溢'),
    ('06045', '非法占绿毁绿（绿地破坏）'), ('07003', '违规户外广告'), ('09005', '店外经营'), ('09006', '占道经营')
  ) as item(standard_code, standard_name)
), scores as (
  select confirmed_standard_code as standard_code,
         count(*) as sample_count,
         count(*) filter (where is_correct) as correct_count
  from public.urban_issue_photo_match_evaluation_v
  where is_high_frequency
    and is_correct is not null
  group by confirmed_standard_code
)
select item.standard_code as "国标代码",
       item.standard_name as "高频事项",
       coalesce(scores.sample_count, 0) as "已复核照片数",
       coalesce(scores.correct_count, 0) as "推荐正确数",
       round(coalesce(scores.correct_count::numeric / nullif(scores.sample_count, 0), 0) * 100, 1) as "准确率(%)",
       case when coalesce(scores.sample_count, 0) >= 5 then '样本量达标' else '每项还需补足至 5 张' end as "样本状态"
from high_frequency item
left join scores on scores.standard_code = item.standard_code
order by item.standard_code;

-- 3. 最终门槛：总计至少 50 张、十项各至少 5 张、总体准确率至少 80%。
with high_frequency as (
  select standard_code from (values
    ('06010'), ('06011'), ('06012'), ('06017'), ('06036'),
    ('06042'), ('06045'), ('07003'), ('09005'), ('09006')
  ) as item(standard_code)
), scores as (
  select confirmed_standard_code as standard_code,
         count(*) as sample_count,
         count(*) filter (where is_correct) as correct_count
  from public.urban_issue_photo_match_evaluation_v
  where is_high_frequency and is_correct is not null
  group by confirmed_standard_code
), summary as (
  select count(*) as high_frequency_count,
         count(*) filter (where coalesce(scores.sample_count, 0) >= 5) as categories_with_enough_samples,
         sum(coalesce(scores.sample_count, 0)) as total_samples,
         sum(coalesce(scores.correct_count, 0)) as total_correct
  from high_frequency
  left join scores using (standard_code)
)
select total_samples as "已复核真实照片总数",
       total_correct as "推荐正确总数",
       round(total_correct::numeric / nullif(total_samples, 0) * 100, 1) as "总体准确率(%)",
       categories_with_enough_samples || '/' || high_frequency_count as "每项至少5张",
       case
         when total_samples >= 50
          and categories_with_enough_samples = high_frequency_count
          and total_correct::numeric / nullif(total_samples, 0) >= 0.80
         then '通过：达到“AI 推荐、人工确认”上线门槛'
         else '未通过：继续补充真实照片并人工复核'
       end as "验收结论"
from summary;
