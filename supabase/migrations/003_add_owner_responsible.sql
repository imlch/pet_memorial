-- ============================================================
--  003_add_owner_responsible.sql
--  家长姓名 + 联系方式 → 合并为「家长负责人」（5 个固定选项：老李/张俊生/迪姐/客服/群聊）
--  注意：老列 owner_name / phone 保留不删，防止历史数据丢失；
--       需要迁移历史数据的话，可在 SQL Editor 里执行末尾的可选迁移语句
-- ============================================================

begin;

-- 1. cells 表新增 owner_responsible 列
alter table public.cells
  add column if not exists owner_responsible text;

comment on column public.cells.owner_responsible
  is '家长负责人，固定选项：老李、张俊生、迪姐、客服、群聊';

-- 2. 重建 updated_at 触发器（如果之前修复脚本删过）（幂等：先删再加，保证列更新时间仍然会变）
drop trigger if exists set_cells_updated_at on public.cells;
create trigger set_cells_updated_at
before update on public.cells
for each row execute function public.handle_updated_at();

-- 3. 诊断输出
select
  (select count(*) from information_schema.columns where table_schema='public' and table_name='cells' and column_name='owner_responsible') as owner_responsible列存在,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='cells' and column_name='owner_name') as 老列owner_name仍保留,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='cells' and column_name='phone')      as 老列phone仍保留;

commit;

-- ============================================================
--  （可选）历史数据一键迁移：把老 owner_name → 填到新 owner_responsible
--  如果 owner_name 不在 5 个固定选项里，会原样保留（前端 select 里显示为空默认值，用户手动选一下即可）
-- ============================================================
-- update public.cells
--    set owner_responsible = owner_name
--  where owner_responsible is null
--    and owner_name is not null
--    and owner_name <> '';
