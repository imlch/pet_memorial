-- ============================================================
-- FIX_04_rls_infinite_recursion.sql
--
-- 解决报错：
--   ERROR  42P17: infinite recursion detected in policy for relation "store_staff"
--   （或 stores/cells/memorials 的同类 infinite recursion）
--
-- 根因：之前的 RLS 策略写了「自引用」或「跨表循环引用」：
--   ❌ policy on store_staff  using (store_id in (select store_id from store_staff where user_id = auth.uid()))
--   ❌ policy on cells        using (store_id in (select id from stores where id in (select store_id from store_staff ...)))
--   Postgres RLS 无法区分「主查询」和「using 子查询」，策略自己会反复触发自己 -> 42P17。
--
-- 解决：创建 2 个 SECURITY DEFINER 辅助函数，
--       它们执行在函数所有者（postgres）的权限下，会 **强制绕过所有 RLS**，
--       策略里只写 =ANY(函数结果)，彻底断开引用环。
--
-- 幂等：可重复执行。
-- ============================================================

-- ---------- 1. 辅助函数 ①：当前用户属于哪些 store_id（返回 uuid[]）----------
-- SECURITY DEFINER + search_path public 保证绕过所有 RLS
drop function if exists public.auth_uid_store_ids();
create or replace function public.auth_uid_store_ids()
returns uuid[] as $$
declare
    v_uid uuid;
begin
    v_uid := auth.uid();
    if v_uid is null then return array[]::uuid[]; end if;
    return array(
        select ss.store_id::uuid
        from public.store_staff ss
        where ss.user_id = v_uid
    );
end;
$$ language plpgsql stable security definer set search_path = public;
alter function public.auth_uid_store_ids() owner to postgres;
grant execute on function public.auth_uid_store_ids() to anon, authenticated, service_role;

-- ---------- 2. 辅助函数 ②：当前用户在 store_staff.role（'owner'/'manager'/'staff'...）----------
drop function if exists public.auth_uid_role(_store_id uuid);
create or replace function public.auth_uid_role(_store_id uuid)
returns text as $$
declare
    v_uid uuid;
    v_role text;
begin
    v_uid := auth.uid();
    if v_uid is null then return null; end if;
    select ss.role into v_role
    from public.store_staff ss
    where ss.user_id   = v_uid
      and ss.store_id  = _store_id
    limit 1;
    return v_role;
end;
$$ language plpgsql stable security definer set search_path = public;
alter function public.auth_uid_role(_store_id uuid) owner to postgres;
grant execute on function public.auth_uid_role(_store_id uuid) to anon, authenticated, service_role;

-- ============================================================
-- 3. 清掉所有 4 张表的所有旧策略（避免残留）
-- ============================================================
drop policy if exists "store_select"   on public.stores;
drop policy if exists "store_update"   on public.stores;
drop policy if exists "store_insert"   on public.stores;
drop policy if exists "store_delete"   on public.stores;

drop policy if exists "cells_select"   on public.cells;
drop policy if exists "cells_insert"   on public.cells;
drop policy if exists "cells_update"   on public.cells;
drop policy if exists "cells_delete"   on public.cells;

drop policy if exists "memorials_select"   on public.memorials;
drop policy if exists "memorials_insert"   on public.memorials;
drop policy if exists "memorials_update"   on public.memorials;
drop policy if exists "memorials_delete"   on public.memorials;

drop policy if exists "ss_select"  on public.store_staff;
drop policy if exists "ss_insert"  on public.store_staff;
drop policy if exists "ss_update"  on public.store_staff;
drop policy if exists "ss_delete"  on public.store_staff;

alter table public.stores        enable row level security;
alter table public.cells         enable row level security;
alter table public.memorials     enable row level security;
alter table public.store_staff   enable row level security;

-- ============================================================
-- 4. 全新策略（全部用 auth_uid_store_ids() 或 auth_uid_role()，彻底无自引用/循环引用）
-- ============================================================

-- 4.1 stores 表
create policy "store_select" on public.stores for select
    using (id = any(public.auth_uid_store_ids()));

create policy "store_update" on public.stores for update
    using (id = any(public.auth_uid_store_ids()) and public.auth_uid_role(id) in ('owner','manager'));

-- 4.2 cells 表
create policy "cells_select" on public.cells for select
    using (store_id = any(public.auth_uid_store_ids()));
create policy "cells_insert" on public.cells for insert
    with check (store_id = any(public.auth_uid_store_ids()));
create policy "cells_update" on public.cells for update
    using (store_id = any(public.auth_uid_store_ids()));
create policy "cells_delete" on public.cells for delete
    using (store_id = any(public.auth_uid_store_ids()));

-- 4.3 memorials 表
-- 要避免 memorials -> cells -> stores -> store_staff -> memorials 环，所以直接查 auth_uid_store_ids()
create policy "memorials_select" on public.memorials for select using (
    exists (
        select 1 from public.cells c
        where c.id = memorials.cell_id and c.store_id = any(public.auth_uid_store_ids())
    )
);
create policy "memorials_insert" on public.memorials for insert with check (
    exists (
        select 1 from public.cells c
        where c.id = memorials.cell_id and c.store_id = any(public.auth_uid_store_ids())
    )
);
create policy "memorials_update" on public.memorials for update using (
    exists (
        select 1 from public.cells c
        where c.id = memorials.cell_id and c.store_id = any(public.auth_uid_store_ids())
    )
);
create policy "memorials_delete" on public.memorials for delete using (
    exists (
        select 1 from public.cells c
        where c.id = memorials.cell_id and c.store_id = any(public.auth_uid_store_ids())
    )
);

-- 4.4 store_staff 表（重点！用 auth_uid_store_ids() 拆自引用）
create policy "ss_select" on public.store_staff for select
    using (store_id = any(public.auth_uid_store_ids()));

create policy "ss_insert" on public.store_staff for insert with check (
    store_id = any(public.auth_uid_store_ids())
    and public.auth_uid_role(store_id) in ('owner','manager')
);

create policy "ss_update" on public.store_staff for update using (
    store_id = any(public.auth_uid_store_ids())
    and public.auth_uid_role(store_id) in ('owner','manager')
);

create policy "ss_delete" on public.store_staff for delete using (
    store_id = any(public.auth_uid_store_ids())
    and (
        public.auth_uid_role(store_id) in ('owner','manager')
        or user_id = auth.uid()          -- 允许普通员工自己退出门店（删除自己那条）
    )
);

-- ============================================================
-- 5. 诊断（让开发者一眼看明白 RLS + 辅助函数授权 对不对）
-- ============================================================
select '🔎  RLS 无限递归 42P17 诊断' as "项", '（共 8 项，如有任何 ❌ 请截图发给开发者）' as "说明"
union all
select '辅助函数 auth_uid_store_ids   授权' as 项,
  case
    when has_function_privilege('authenticated','public.auth_uid_store_ids()','execute')
      and has_function_privilege('anon','public.auth_uid_store_ids()','execute')
    then '✅ 正常' else '❌ 缺少授权（函数无法调用，策略等于空=查不到任何数据）' end
union all
select '辅助函数 auth_uid_role        授权' as 项,
  case when has_function_privilege('authenticated','public.auth_uid_role(uuid)','execute')
    and has_function_privilege('anon','public.auth_uid_role(uuid)','execute')
    then '✅ 正常' else '❌ 缺少授权' end
union all
select 'store_staff  策略数（应该是 4）' as 项, count(*)::text
from pg_policy
join pg_class on pg_class.oid = pg_policy.polrelid
join pg_namespace on pg_namespace.oid = pg_class.relnamespace
where pg_namespace.nspname='public' and pg_class.relname='store_staff'
union all
select 'stores       策略数（应该是 2）' as 项, count(*)::text
from pg_policy
join pg_class on pg_class.oid = pg_policy.polrelid
join pg_namespace on pg_namespace.oid = pg_class.relnamespace
where pg_namespace.nspname='public' and pg_class.relname='stores'
union all
select 'cells        策略数（应该是 4）' as 项, count(*)::text
from pg_policy
join pg_class on pg_class.oid = pg_policy.polrelid
join pg_namespace on pg_namespace.oid = pg_class.relnamespace
where pg_namespace.nspname='public' and pg_class.relname='cells'
union all
select 'memorials    策略数（应该是 4）' as 项, count(*)::text
from pg_policy
join pg_class on pg_class.oid = pg_policy.polrelid
join pg_namespace on pg_namespace.oid = pg_class.relnamespace
where pg_namespace.nspname='public' and pg_class.relname='memorials'
union all
select '当前 auth 用户数（>0=正常）' as 项, count(*)::text from auth.users;

select '🎉 FIX_04 完成。现在刷新前端页面 → 用员工账号登录 → 重新点「保存纪念日」试试' as "最终结果";
