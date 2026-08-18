-- ============================================================
-- 002_add_staff_and_invite.sql
-- 功能：多员工同步 + 邀请码机制
-- 幂等：可反复执行，不会影响已有数据
-- 适用：已经跑过 001_init_schema.sql / FIX_01_register_error_all.sql 的项目
-- ============================================================

-- ---------- 1. 给 stores 表加邀请码字段（如果没加） ----------
do $$
begin
    if not exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='stores' and column_name='invite_code'
    ) then
        alter table public.stores
            add column invite_code   text unique,
            add column created_by_email text;
    end if;
end $$;

-- 给已有的老门店（owner 已注册但没邀请码）的生成随机邀请码
update public.stores
   set invite_code = (
       select string_agg(
           case (random()*35)::int
               when 0 then 'A' when 1 then 'B' when 2 then 'C' when 3 then 'D' when 4 then 'E'
               when 5 then 'F' when 6 then 'G' when 7 then 'H' when 8 then 'J' when 9 then 'K'
               when 10 then 'M' when 11 then 'N' when 12 then 'P' when 13 then 'Q' when 14 then 'R'
               when 15 then 'T' when 16 then 'U' when 17 then 'V' when 18 then 'W' when 19 then 'X'
               when 20 then 'Y' when 21 then 'Z' when 22 then '2' when 23 then '3' when 24 then '4'
               when 25 then '5' when 26 then '6' when 27 then '7' when 28 then '8' when 29 then '9'
               when 30 then 'A' when 31 then 'B' when 32 then 'C' when 33 then 'D' when 34 then 'E'
               when 35 then 'F'
           end, ''
       )
       from generate_series(1,6)
   ),
       created_by_email = coalesce(created_by_email, (select email from auth.users u where u.id = stores.owner_id))
 where invite_code is null;

-- 加非空约束（上面已经填完了）
alter table public.stores alter column invite_code set not null;

-- ---------- 2. 新建员工关联表 store_staff ----------
create table if not exists public.store_staff (
    id         uuid primary key default gen_random_uuid(),
    store_id   uuid not null references public.stores(id) on delete cascade,
    user_id    uuid not null references auth.users(id) on delete cascade,
    role       text not null default 'staff',  -- owner / manager / staff
    full_name  text,
    invited_by uuid references auth.users(id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (store_id, user_id),
    unique (user_id)   -- 一个用户只能属于一家门店
);

create index if not exists idx_store_staff_store on public.store_staff(store_id);
create index if not exists idx_store_staff_user  on public.store_staff(user_id);

-- updated_at 触发器
drop trigger if exists trg_store_staff_updated on public.store_staff;
create trigger trg_store_staff_updated
    before update on public.store_staff
    for each row execute function public.set_updated_at();

-- ---------- 3. 把现有 stores 表里的老 owner 补进 store_staff 作为 owner ----------
insert into public.store_staff (store_id, user_id, role, full_name, invited_by, created_at, updated_at)
select
    s.id,
    s.owner_id,
    'owner',
    u.email,
    null,
    s.created_at,
    now()
from public.stores s
join auth.users u on u.id = s.owner_id
where not exists (
    select 1 from public.store_staff ss where ss.user_id = s.owner_id
);

-- ---------- 4. 【关键】重新创建 注册触发器（现在支持两种模式） ----------
drop trigger if exists trg_auth_create_store on auth.users;
drop function if exists public.handle_new_user_create_store();

create or replace function public.handle_new_user_create_store()
returns trigger as $$
declare
    v_invite     text;
    v_store_name text;
    v_full_name  text;
    v_store_id   uuid;
    v_existing   uuid;
    v_target_store uuid;
begin
    -- 读取 meta（前端注册时塞进 options.data 的）
    v_invite     := btrim(new.raw_user_meta_data ->> 'invite_code');
    v_store_name := coalesce(new.raw_user_meta_data ->> 'store_name', split_part(new.email, '@', 1) || '的门店');
    v_full_name  := coalesce(new.raw_user_meta_data ->> 'full_name', new.email);

    -- 如果用户已经有门店归属（理论上不会有），直接跳过
    select ss.store_id into v_existing
    from public.store_staff ss where ss.user_id = new.id limit 1;
    if v_existing is not null then return new; end if;

    if v_invite is not null and length(v_invite) = 6 then
        -- ============ 模式 B：员工加入已有门店（邀请码） ============
        select s.id into v_target_store
        from public.stores s where s.invite_code = upper(v_invite) limit 1;

        if v_target_store is null then
            raise exception '邀请码 % 不存在，请向店主核实', v_invite;
        end if;

        -- 插入 store_staff，身份 = staff
        insert into public.store_staff (store_id, user_id, role, full_name)
        values (v_target_store, new.id, 'staff', v_full_name);

    else
        -- ============ 模式 A：店主创建新门店（默认） ============
        insert into public.stores (owner_id, name, rows_config, cols_config, pattern_config, created_by_email, invite_code)
        values (new.id, v_store_name, 8, 15, '["small","small","large"]', new.email, (
            select string_agg(
                case (random()*35)::int
                    when 0 then 'A' when 1 then 'B' when 2 then 'C' when 3 then 'D' when 4 then 'E'
                    when 5 then 'F' when 6 then 'G' when 7 then 'H' when 8 then 'J' when 9 then 'K'
                    when 10 then 'M' when 11 then 'N' when 12 then 'P' when 13 then 'Q' when 14 then 'R'
                    when 15 then 'T' when 16 then 'U' when 17 then 'V' when 18 then 'W' when 19 then 'X'
                    when 20 then 'Y' when 21 then 'Z' when 22 then '2' when 23 then '3' when 24 then '4'
                    when 25 then '5' when 26 then '6' when 27 then '7' when 28 then '8' when 29 then '9'
                    when 30 then 'A' when 31 then 'B' when 32 then 'C' when 33 then 'D' when 34 then 'E'
                    when 35 then 'F'
                end, ''
            )
            from generate_series(1,6)
        )) returning id into v_store_id;

        -- 把创建者作为 owner 写进 store_staff
        insert into public.store_staff (store_id, user_id, role, full_name)
        values (v_store_id, new.id, 'owner', coalesce(v_full_name, v_store_name));
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

-- ---------- 5. 【关键】重建所有 RLS 策略：现在用 store_staff 判断身份 ----------
alter table public.stores     enable row level security;
alter table public.cells      enable row level security;
alter table public.memorials  enable row level security;
alter table public.store_staff enable row level security;

-- stores 策略：我属于这家门店才能看
drop policy if exists "store_select" on public.stores;
drop policy if exists "store_update" on public.stores;
create policy "store_select" on public.stores
    for select using (
        id in (select store_id from public.store_staff where user_id = auth.uid())
    );
create policy "store_update" on public.stores
    for update using (
        -- 只有 owner 或 manager 能改门店信息
        id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
    );

-- cells 策略：同 store 的所有员工都能 CRUD
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

-- memorials 策略
drop policy if exists "memorials_select" on public.memorials;
drop policy if exists "memorials_insert" on public.memorials;
drop policy if exists "memorials_update" on public.memorials;
drop policy if exists "memorials_delete" on public.memorials;
create policy "memorials_select" on public.memorials
    for select using (cell_id in (
        select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
    ));
create policy "memorials_insert" on public.memorials
    for insert with check (cell_id in (
        select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
    ));
create policy "memorials_update" on public.memorials
    for update using (cell_id in (
        select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
    ));
create policy "memorials_delete" on public.memorials
    for delete using (cell_id in (
        select c.id from public.cells c where c.store_id in (select store_id from public.store_staff where user_id = auth.uid())
    ));

-- store_staff 表策略：我属于这家门店就能看，只有 owner/manager 能增删改
drop policy if exists "ss_select" on public.store_staff;
drop policy if exists "ss_insert" on public.store_staff;
drop policy if exists "ss_update" on public.store_staff;
drop policy if exists "ss_delete" on public.store_staff;
create policy "ss_select" on public.store_staff
    for select using (store_id in (select store_id from public.store_staff where user_id = auth.uid()));
create policy "ss_insert" on public.store_staff
    for insert with check (
        store_id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
    );
create policy "ss_update" on public.store_staff
    for update using (
        store_id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
    );
create policy "ss_delete" on public.store_staff
    for delete using (
        store_id in (select store_id from public.store_staff where user_id = auth.uid() and role in ('owner','manager'))
        or user_id = auth.uid()   -- 自己能退出门店
    );

-- ---------- 6. 重建 RPC：get_my_store 现在要返回角色、邀请码 ----------
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
grant execute on function public.get_my_store() to authenticated, anon;

-- ---------- 7. 新增 RPC：店主重置邀请码 ----------
create or replace function public.reset_store_invite_code()
returns text as $$
declare
    v_store_id uuid;
    v_role     text;
    v_new_code text;
begin
    select ss.store_id, ss.role into v_store_id, v_role
    from public.store_staff ss
    where ss.user_id = auth.uid() limit 1;

    if v_store_id is null then
        raise exception '你还不属于任何门店';
    end if;
    if v_role <> 'owner' then
        raise exception '只有店主可以重置邀请码';
    end if;

    -- 生成一个新的 6 位邀请码（避开易错字符 I L O S 0 1）
    loop
        select string_agg(
            case (random()*35)::int
                when 0 then 'A' when 1 then 'B' when 2 then 'C' when 3 then 'D' when 4 then 'E'
                when 5 then 'F' when 6 then 'G' when 7 then 'H' when 8 then 'J' when 9 then 'K'
                when 10 then 'M' when 11 then 'N' when 12 then 'P' when 13 then 'Q' when 14 then 'R'
                when 15 then 'T' when 16 then 'U' when 17 then 'V' when 18 then 'W' when 19 then 'X'
                when 20 then 'Y' when 21 then 'Z' when 22 then '2' when 23 then '3' when 24 then '4'
                when 25 then '5' when 26 then '6' when 27 then '7' when 28 then '8' when 29 then '9'
                when 30 then 'A' when 31 then 'B' when 32 then 'C' when 33 then 'D' when 34 then 'E'
                when 35 then 'F'
            end, ''
        ) into v_new_code from generate_series(1,6);

        exit when not exists (select 1 from public.stores where invite_code = v_new_code);
    end loop;

    update public.stores set invite_code = v_new_code where id = v_store_id;
    return v_new_code;
end;
$$ language plpgsql volatile security definer set search_path = public;
alter function public.reset_store_invite_code() owner to postgres;
grant execute on function public.reset_store_invite_code() to authenticated;

-- ---------- 8. 整体授权 ----------
grant usage   on schema public to anon, authenticated;
grant select, insert, update, delete on public.stores        to authenticated;
grant select, insert, update, delete on public.cells         to authenticated;
grant select, insert, update, delete on public.memorials     to authenticated;
grant select, insert, update, delete on public.store_staff   to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant select on public.stores, public.cells, public.memorials, public.store_staff to anon;

-- ---------- 完成 ----------
select '✅ 员工同步+邀请码 迁移完成！' as "结果"
union all
select '已有门店数: ' || count(*)::text from public.stores
union all
select '已关联员工数: ' || count(*)::text from public.store_staff;
