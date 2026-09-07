-- ============================================================
-- FIX_05_sync_perf_and_staff_bugs.sql
--
-- 解决 2 类同步问题：
--   ①  员工/店长角色点击「同步」后，get_store_grid 返回 0 条数据 → 前端会弹 confirm 二次确认，
--      但根本原因是原 SQL 写了 `where s.owner_id = auth.uid()`，只认店主！
--   ②  get_store_grid 里「每一行 cells 做一次子查询 jsonb_agg(memorials)」是 N+1 反模式，
--      8×15=120 格会执行 1+120 次子查询，数据量大会慢 → 用 CTE 预聚合 1 次 JOIN 搞定。
--   ③  补 `owner_responsible` 新列（003 migration 加的列，但原 get_store_grid 没 select）。
--
-- 幂等：可重复执行。
-- 需要：先跑过 FIX_04（因为这里用了 auth_uid_store_ids()）
-- ============================================================

-- ---------- 1. 重建 get_store_grid（3 项修复一次性打包）----------
drop function if exists public.get_store_grid();
create or replace function public.get_store_grid()
returns jsonb as $$
declare
    result jsonb;
begin
    -- 用 CTE 一次性把所有 memorials 按 cell_id 聚合成 JSON 数组，后面只 JOIN 1 次（消除 N+1）
    with memorials_agg as (
        select
            m.cell_id,
            coalesce(jsonb_agg(jsonb_build_object(
                'id',     m.id,
                'label',  m.label,
                'date',   to_char(m.memorial_date, 'YYYY-MM-DD'),
                'repeat', m.repeat_type
            ) order by m.id asc), '[]'::jsonb) as memorials
        from public.memorials m
        group by m.cell_id
    )
    select jsonb_build_object(
        'cells', coalesce(jsonb_agg(cell_data), '[]'::jsonb)
    ) into result
    from (
        select
            c.cell_key,
            c.row_num,
            c.col_num,
            c.pet_name,
            c.breed,
            c.owner_name,              -- 保留老字段向后兼容
            c.owner_responsible,       -- ★ 003 新列：家长负责人
            c.farewell_date,           -- ★ 004 新列：告别日期
            c.storage_period,          -- ★ 004 新列：寄存期限（七天 / 49天 / 一年）
            c.phone,
            to_char(c.check_in,    'YYYY-MM-DD') as check_in,
            to_char(c.farewell_date,'YYYY-MM-DD') as farewell_date_str,
            c.notes,
            coalesce(ma.memorials, '[]'::jsonb) as memorials
        from public.cells c
        left join memorials_agg ma on ma.cell_id = c.id
        -- ★ 关键修复：之前写的是 s.owner_id = auth.uid()，导致员工/店长返回空！
        --   现在用 FIX_04 的辅助函数 auth_uid_store_ids()，只要 store_staff 里有记录就能查到。
        where c.store_id = any(public.auth_uid_store_ids())
        order by c.row_num, c.col_num
    ) cell_data;

    return result;
end;
$$ language plpgsql stable security definer set search_path = public;

alter function public.get_store_grid() owner to postgres;
revoke all on function public.get_store_grid() from public;
grant execute on function public.get_store_grid() to anon, authenticated, service_role;

comment on function public.get_store_grid() is
'获取门店所有格子+纪念日（一次性返回）。v3 修复：员工/店长也能查到；补 owner_responsible/farewell_date/storage_period 列；N+1→CTE 聚合提升性能。';

-- ---------- 2. 诊断：让用户一眼确认修复生效 ----------
select '🔎  FIX_05 v3 同步性能 + 员工权限 + 告别日期/寄存期限 诊断（共 7 项）' as "项", '' as "说明"
union all
select 'get_store_grid 函数是否包含 owner_responsible' as 项,
  case when prosrc like '%owner_responsible%'
    then '✅ 已包含（家长负责人同步不丢）' else '❌ 未包含，重新执行本 SQL' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='get_store_grid'
union all
select 'get_store_grid 函数是否包含 farewell_date' as 项,
  case when prosrc like '%farewell_date%'
    then '✅ 已包含（告别日期同步不丢）' else '❌ 未包含，请先跑 004 再跑本 FIX_05' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='get_store_grid'
union all
select 'get_store_grid 函数是否包含 storage_period' as 项,
  case when prosrc like '%storage_period%'
    then '✅ 已包含（寄存期限同步不丢）' else '❌ 未包含，请先跑 004 再跑本 FIX_05' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='get_store_grid'
union all
select 'get_store_grid 是否用 auth_uid_store_ids()' as 项,
  case when prosrc like '%auth_uid_store_ids()%'
    then '✅ 已修复（员工/店长同步能拿到数据）' else '❌ 仍用旧的 owner_id 过滤，员工会返回 0 条' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='get_store_grid'
union all
select 'get_store_grid 是否用了 memorials_agg CTE' as 项,
  case when prosrc like '%memorials_agg%'
    then '✅ 已改为 CTE 一次聚合（消除 N+1，性能提升）' else '⚠️  还是 N+1 子查询写法' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='get_store_grid'
union all
select 'execute 授权是否给了 authenticated' as 项,
  case when has_function_privilege('authenticated','public.get_store_grid()','execute')
    then '✅ 正常' else '❌ 缺少授权，前端 RPC 会返回空或报错' end;

select '🎉 FIX_05 完成。刷新前端页面 → 用员工账号登录 → 点「🔄 同步」 → 应该能看到数据而不是 0 条弹窗了。' as "最终结果";
