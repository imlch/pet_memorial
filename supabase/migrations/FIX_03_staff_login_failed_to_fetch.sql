-- ============================================================
-- FIX_03_staff_login_failed_to_fetch.sql
-- 作用：修复「店员账号注册成功，但一登录就报 Failed to fetch」这个高频问题
-- 典型根因：
--   ①  店员注册成功，但 auth.users -> store_staff 的触发器因权限/异常 没插入成功
--   ②  get_my_store / get_store_grid 两个 RPC 忘记 grant execute to authenticated （最常见！）
--   ③  store_staff / cells / memorials RLS 策略缺失/错写导致 42501 permission denied
--   ④  auth 触发器函数没授权给 supabase_auth_admin 角色，触发器 静默失败/不执行
--   ⑤  店员在 auth.users 里存在，但 store_staff 没他的记录，登录后 get_my_store 空数组
-- 幂等：反复执行不会破坏任何已有数据
-- ============================================================

-- ---------- 0. 先跑诊断输出（给开发者看，有 ❌ 的就是问题所在） ----------
create or replace function public.gen_unique_invite_code()
returns text as $$
declare
    v_chars  text := 'ABCDEFGHJKMNPQRTUVWXYZ23456789';
    v_code   text;
    v_loops  int  := 0;
begin
    loop
        v_loops := v_loops + 1;
        if v_loops <= 500 then
            select string_agg(substr(v_chars, (random() * (length(v_chars)-1) + 1)::int, 1), '')
              into v_code from generate_series(1,6);
        else
            select string_agg(substr(v_chars, (random() * (length(v_chars)-1) + 1)::int, 1), '')
              into v_code from generate_series(1,7);
        end if;
        exit when not exists (select 1 from public.stores where invite_code = v_code);
    end loop;
    return v_code;
end;
$$ language plpgsql volatile;
alter function public.gen_unique_invite_code() owner to postgres;
grant execute on function public.gen_unique_invite_code() to postgres, authenticated;

-- ---------- 诊断输出 ----------
unlisten *;
select '🔎 正在诊断店员登录 Failed to fetch 的原因...' as "提示";
-- 1. auth.users 表有多少用户 vs store_staff 有多少条
select
  '① auth用户总数' as 项, count(*)::text as 值 from auth.users
union all
select
  '① store_staff记录数（应该≥auth用户数）' as 项, count(*)::text as 值 from public.store_staff
union all
select
  '❌ 缺失记录的用户数（=应该>0就是问题）' as 项, count(*)::text as 值
from auth.users u
where not exists (select 1 from public.store_staff ss where ss.user_id = u.id);

-- 2. 检查两个 RPC 函数的 execute 授权
select
  case when has_function_privilege('anon','public.get_my_store()','execute')
    and has_function_privilege('authenticated','public.get_my_store()','execute')
    then '✅ get_my_store 授权正常'
  else '❌ get_my_store 缺少 execute 授权 ——— 就是这个！'
  end as 检查_RPC_get_my_store
union all
select
  case when has_function_privilege('anon','public.get_store_grid()','execute')
    and has_function_privilege('authenticated','public.get_store_grid()','execute')
    then '✅ get_store_grid 授权正常'
  else '❌ get_store_grid 缺少 execute 授权 ——— 就是这个！'
  end as 检查_RPC_get_store_grid;

-- 3. store_staff 上挂的 auth 触发器是否完整
select
  case when exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'auth' and c.relname = 'users'
      and t.tgname = 'trg_auth_create_store'
  ) then '✅ auth.users 触发器已挂好' else '❌ auth.users 没有 trg_auth_create_store 触发器 —— 店员注册后不会自动进 store_staff！'
  end as 检查_auth_users_触发器
union all
select
  case when has_function_privilege('supabase_auth_admin','public.handle_new_user_create_store()','execute')
    then '✅ 触发器函数 supabase_auth_admin 授权正常'
  else '❌ 触发器函数未授权给 supabase_auth_admin —— 注册时触发器静默失败！'
  end as 检查_触发器_授权;

-- ---------- 1. 【核心修复】给所有表、所有 RPC 做全量授权（覆盖所有遗漏） ----------
grant usage   on schema public to anon, authenticated;
grant select, insert, update, delete on public.stores       to authenticated;
grant select, insert, update, delete on public.cells        to authenticated;
grant select, insert, update, delete on public.memorials    to authenticated;
grant select, insert, update, delete on public.store_staff  to authenticated;
grant select on public.stores, public.cells, public.memorials, public.store_staff to anon;
grant usage, select on all sequences in schema public to authenticated;

-- 两个 RPC
drop function if exists public.get_my_store();
create or replace function public.get_my_store()
returns table (
    store_id       uuid,
    name           text,
    address        text,
    contact_phone  text,
    rows_config    int,
    cols_config    int,
    pattern_config text,
    invite_code    text,
    my_role        text,
    my_full_name   text
) as $$
begin
    return query
        select s.id, s.name, s.address, s.contact_phone,
               s.rows_config, s.cols_config, s.pattern_config,
               s.invite_code, ss.role, ss.full_name
        from public.stores s
        join public.store_staff ss on ss.store_id = s.id
        where ss.user_id = auth.uid()
        limit 1;
end;
$$ language plpgsql stable security definer set search_path = public;
alter function public.get_my_store() owner to postgres;
grant execute on function public.get_my_store() to anon, authenticated;

drop function if exists public.get_store_grid();
create or replace function public.get_store_grid()
returns jsonb as $$
declare
    v_result jsonb;
begin
    select jsonb_build_object(
        'cells', coalesce(jsonb_agg(cell_data), '[]'::jsonb)
    ) into v_result
    from (
        select
            c.cell_key,
            c.row_num,
            c.col_num,
            c.pet_name,
            c.breed,
            c.owner_name,
            c.phone,
            to_char(c.check_in, 'YYYY-MM-DD') as check_in,
            c.notes,
            coalesce((
                select jsonb_agg(jsonb_build_object(
                    'id',    m.id,
                    'label', m.label,
                    'date',  to_char(m.memorial_date, 'YYYY-MM-DD'),
                    'repeat', m.repeat_type
                ))
                from public.memorials m where m.cell_id = c.id
            ), '[]'::jsonb) as memorials
        from public.cells c
        join public.stores s on c.store_id = s.id
        where s.id in (select store_id from public.store_staff where user_id = auth.uid())
        order by c.row_num, c.col_num
    ) cell_data;
    return v_result;
end;
$$ language plpgsql stable security definer set search_path = public;
alter function public.get_store_grid() owner to postgres;
grant execute on function public.get_store_grid() to anon, authenticated;

-- 重置邀请码 RPC
drop function if exists public.reset_store_invite_code();
create or replace function public.reset_store_invite_code()
returns text as $$
declare
    v_store_id uuid;
    v_role     text;
    v_new_code text;
begin
    select ss.store_id, ss.role into v_store_id, v_role
    from public.store_staff ss where ss.user_id = auth.uid() limit 1;
    if v_store_id is null then raise exception '你还不属于任何门店'; end if;
    if v_role <> 'owner' then raise exception '只有店主可以重置邀请码'; end if;
    loop
        v_new_code := public.gen_unique_invite_code();
        exit when not exists (select 1 from public.stores where invite_code = v_new_code);
    end loop;
    update public.stores set invite_code = v_new_code where id = v_store_id;
    return v_new_code;
end;
$$ language plpgsql volatile security definer set search_path = public;
alter function public.reset_store_invite_code() owner to postgres;
grant execute on function public.reset_store_invite_code() to authenticated;

-- ---------- 2. 【核心修复】重建 auth.users -> store_staff 触发器（双模式） ----------
drop trigger if exists trg_auth_create_store on auth.users;
drop function if exists public.handle_new_user_create_store();

create or replace function public.handle_new_user_create_store()
returns trigger as $$
declare
    v_invite     text;
    v_store_name text;
    v_full_name  text;
    v_store_id   uuid;
    v_target     uuid;
begin
    v_invite     := btrim(new.raw_user_meta_data ->> 'invite_code');
    v_store_name := coalesce(new.raw_user_meta_data ->> 'store_name', split_part(new.email, '@', 1) || '的门店');
    v_full_name  := coalesce(new.raw_user_meta_data ->> 'full_name',  new.email);

    if exists (select 1 from public.store_staff ss where ss.user_id = new.id) then
        return new;
    end if;

    if v_invite is not null and length(v_invite) = 6 then
        select s.id into v_target from public.stores s
         where s.invite_code = upper(v_invite) limit 1;
        if v_target is null then
            raise exception '邀请码 % 不存在，请向店主核实', v_invite;
        end if;
        insert into public.store_staff (store_id, user_id, role, full_name)
        values (v_target, new.id, 'staff', v_full_name)
        on conflict (user_id) do nothing;
    else
        insert into public.stores (owner_id, name, rows_config, cols_config, pattern_config, created_by_email, invite_code)
        values (new.id, v_store_name, 8, 15, '["small","small","large"]', new.email, public.gen_unique_invite_code())
        returning id into v_store_id;

        insert into public.store_staff (store_id, user_id, role, full_name)
        values (v_store_id, new.id, 'owner', v_full_name)
        on conflict (user_id) do nothing;
    end if;
    return new;
end;
$$ language plpgsql security definer set search_path = public;

alter function public.handle_new_user_create_store() owner to postgres;
grant execute on function public.handle_new_user_create_store() to postgres;
grant execute on function public.handle_new_user_create_store() to supabase_auth_admin;

create trigger trg_auth_create_store
    after insert on auth.users
    for each row execute function public.handle_new_user_create_store();

-- ---------- 3. 【核心修复】把老的 auth.users 中「已经注册成功但 store_staff 没记录」的员工补进去 ----------
-- 策略：先按 raw_user_meta_data.invite_code 匹配门店；如果没邀请码按邮箱/owner_id 匹配老 owner；实在没法匹配，留空让用户下次重登自动补（但其实我们已经重建了触发器不会再漏）
do $$
declare
    r record;
    v_invite   text;
    v_store_id uuid;
    v_store_name text;
    v_full_name text;
begin
    for r in
        select u.id, u.email, u.raw_user_meta_data
        from auth.users u
        where not exists (select 1 from public.store_staff ss where ss.user_id = u.id)
        order by u.created_at asc
    loop
        v_invite     := upper(btrim(r.raw_user_meta_data ->> 'invite_code' ));
        v_store_name := coalesce(r.raw_user_meta_data ->> 'store_name', split_part(r.email, '@', 1) || '的门店');
        v_full_name  := coalesce(r.raw_user_meta_data ->> 'full_name',  r.email);

        if v_invite is not null and length(v_invite) = 6 then
            select id into v_store_id from public.stores where invite_code = v_invite limit 1;
            if v_store_id is not null then
                insert into public.store_staff (store_id, user_id, role, full_name)
                values (v_store_id, r.id, 'staff', v_full_name)
                on conflict (user_id) do nothing;
                continue;
            end if;
        end if;

        -- 如果是老店主（之前的 owner_id 匹配的 stores）直接拉进 store_staff
        select id into v_store_id from public.stores where owner_id = r.id limit 1;
        if v_store_id is not null then
            insert into public.store_staff (store_id, user_id, role, full_name)
            values (v_store_id, r.id, 'owner', v_full_name)
            on conflict (user_id) do nothing;
            continue;
        end if;

        -- 实在没匹配：给他自己创建一家新的单人门店（兜底，确保不出现"空门店导致登录失败"）
        insert into public.stores (owner_id, name, rows_config, cols_config, pattern_config, created_by_email, invite_code)
        values (r.id, v_store_name, 8, 15, '["small","small","large"]', r.email, public.gen_unique_invite_code())
        returning id into v_store_id;

        insert into public.store_staff (store_id, user_id, role, full_name)
        values (v_store_id, r.id, 'owner', v_full_name)
        on conflict (user_id) do nothing;
    end loop;
end $$;

-- ---------- 4. 重建所有表的 RLS（确保店员能查自己门店的数据） ----------
alter table public.stores        enable row level security;
alter table public.cells         enable row level security;
alter table public.memorials     enable row level security;
alter table public.store_staff   enable row level security;

drop policy if exists "store_select" on public.stores;
drop policy if exists "store_update" on public.stores;
create policy "store_select" on public.stores
    for select using (id in (select store_id from public.store_staff where user_id = auth.uid()));
create policy "store_update" on public.stores
    for update using (
        id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
    );

drop policy if exists "cells_select" on public.cells;
drop policy if exists "cells_insert" on public.cells;
drop policy if exists "cells_update" on public.cells;
drop policy if exists "cells_delete" on public.cells;
create policy "cells_select" on public.cells
    for select using (store_id in (select store_id from public.store_staff where user_id = auth.uid()));
create policy "cells_insert" on public.cells
    for insert with check (store_id in (select store_id from public.store_staff where user_id = auth.uid()));
create policy "cells_update" on public.cells
    for update using (store_id in (select store_id from public.store_staff where user_id = auth.uid()));
create policy "cells_delete" on public.cells
    for delete using (store_id in (select store_id from public.store_staff where user_id = auth.uid()));

drop policy if exists "memorials_select" on public.memorials;
drop policy if exists "memorials_insert" on public.memorials;
drop policy if exists "memorials_update" on public.memorials;
drop policy if exists "memorials_delete" on public.memorials;
create policy "memorials_select" on public.memorials for select using (cell_id in (
    select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
));
create policy "memorials_insert" on public.memorials for insert with check (cell_id in (
    select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
));
create policy "memorials_update" on public.memorials for update using (cell_id in (
    select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
));
create policy "memorials_delete" on public.memorials for delete using (cell_id in (
    select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
));

drop policy if exists "ss_select" on public.store_staff;
drop policy if exists "ss_insert" on public.store_staff;
drop policy if exists "ss_update" on public.store_staff;
drop policy if exists "ss_delete" on public.store_staff;
create policy "ss_select" on public.store_staff
    for select using (store_id in (select store_id from public.store_staff where user_id = auth.uid()));
create policy "ss_insert" on public.store_staff for insert with check (
    store_id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
);
create policy "ss_update" on public.store_staff for update using (
    store_id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
);
create policy "ss_delete" on public.store_staff for delete using (
    store_id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
    or user_id = auth.uid()
);

-- ---------- 5. 诊断报告（跑完给开发者看一眼） ----------
select '🎉 FIX_03 执行完成！修复了以下常见问题：' as "✅ 结果"
union all
select '  · 重建并重新授权 get_my_store / get_store_grid / reset_store_invite_code 三个 RPC'
union all
select '  · 重建 auth.users 注册触发器（确保店员/店主都能进 store_staff）并 grant 给 supabase_auth_admin'
union all
select '  · 补全了所有 auth.users 的 store_staff 缺失记录（最可能是之前注册的店员没进关联表导致 get_my_store 空数组）'
union all
select '  · 重建 stores / cells / memorials / store_staff 的 RLS 策略'
union all
select '现在请刷新前端页面 → 用店员账号重新登录，如果仍失败，打开 F12 → Network 点红的请求看 Preview 把具体报错贴出来'
union all
select '或者运行本脚本最开头的 2 条诊断 SQL，看哪一条显示 ❌';
