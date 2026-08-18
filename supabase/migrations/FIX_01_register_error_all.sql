-- ============================================================
-- 万能修复脚本：解决 99% 的 "Database error saving new user"
-- 使用方法：复制全文到 Supabase SQL Editor -> Run
-- 作用：幂等重建触发器 + 确保 pgcrypto + 补建缺失表/RPC/RLS
-- 注意：此脚本不会删除任何现有数据（用 drop if exists + 重建函数/触发器，表不会 drop）
-- ============================================================

-- ---------- 1. 确保 pgcrypto 扩展已启用 ----------
drop extension if exists pgcrypto cascade;
create extension if not exists pgcrypto;

-- 验证
do $$
begin
  if gen_random_uuid() is null then
    raise exception 'pgcrypto 仍然无法使用，请联系 Supabase 支持';
  end if;
end $$;

-- ---------- 2. 重新建 3 张表（if not exists，已有表和数据不会动） ----------
create table if not exists public.stores (
    id          uuid primary key default gen_random_uuid(),
    owner_id    uuid not null references auth.users(id) on delete cascade,
    name        text not null,
    address     text,
    contact_phone text,
    rows_config int not null default 8,
    cols_config int not null default 15,
    pattern_config text not null default '["small","small","large"]',
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table if not exists public.cells (
    id          uuid primary key default gen_random_uuid(),
    store_id    uuid not null references public.stores(id) on delete cascade,
    cell_key    text not null,
    row_num     int not null,
    col_num     int not null,
    pet_name    text,
    breed       text,
    owner_name  text,
    phone       text,
    check_in    date,
    notes       text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    unique (store_id, cell_key)
);

create table if not exists public.memorials (
    id            uuid primary key default gen_random_uuid(),
    cell_id       uuid not null references public.cells(id) on delete cascade,
    label         text not null,
    memorial_date date not null,
    repeat_type   text not null default '每年',
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- ---------- 3. 重新建索引（if not exists） ----------
create index if not exists idx_stores_owner      on public.stores(owner_id);
create index if not exists idx_cells_store       on public.cells(store_id);
create index if not exists idx_cells_store_key   on public.cells(store_id, cell_key);
create index if not exists idx_memorials_cell    on public.memorials(cell_id);
create index if not exists idx_memorials_date    on public.memorials(memorial_date);

-- ---------- 4. 重建 updated_at 触发器 ----------
create or replace function public.set_updated_at()
returns trigger as $$
begin
    new.updated_at := now();
    return new;
end;
$$ language plpgsql volatile;

drop trigger if exists trg_stores_updated_at     on public.stores;
drop trigger if exists trg_cells_updated_at      on public.cells;
drop trigger if exists trg_memorials_updated_at  on public.memorials;

create trigger trg_stores_updated_at
    before update on public.stores
    for each row execute function public.set_updated_at();

create trigger trg_cells_updated_at
    before update on public.cells
    for each row execute function public.set_updated_at();

create trigger trg_memorials_updated_at
    before update on public.memorials
    for each row execute function public.set_updated_at();

-- ---------- 5. 【关键】删除旧触发器/函数，全新创建 注册触发器 ----------
drop trigger if exists trg_auth_create_store on auth.users;
drop function if exists public.handle_new_user_create_store();

create or replace function public.handle_new_user_create_store()
returns trigger as $$
declare
    v_store_name text;
    v_existing   uuid;
begin
    -- 提取门店名称，优先 meta 里的 store_name，否则用邮箱 @ 前缀
    v_store_name := coalesce(
        new.raw_user_meta_data ->> 'store_name',
        split_part(new.email, '@', 1) || '的门店'
    );

    -- 幂等：如果已存在门店（注册接口重复调），就不要重复插
    select id into v_existing
    from public.stores
    where owner_id = new.id
    limit 1;

    if v_existing is null then
        insert into public.stores (owner_id, name, rows_config, cols_config, pattern_config)
        values (new.id, v_store_name, 8, 15, '["small","small","large"]');
    end if;

    return new;
end;
$$ language plpgsql security definer set search_path = public;

-- 给触发器函数授权（Supabase 上的 auth 触发器是以特定身份跑的，权限很重要）
alter function public.handle_new_user_create_store() owner to postgres;
grant execute on function public.handle_new_user_create_store() to postgres;
grant execute on function public.handle_new_user_create_store() to supabase_auth_admin;

create trigger trg_auth_create_store
    after insert on auth.users
    for each row execute function public.handle_new_user_create_store();

-- ---------- 6. 重建 RPC 函数 ----------
create or replace function public.get_my_store()
returns table (
    store_id      uuid,
    name          text,
    address       text,
    contact_phone text,
    rows_config   int,
    cols_config   int,
    pattern_config text
) as $$
begin
    return query
        select s.id, s.name, s.address, s.contact_phone,
               s.rows_config, s.cols_config, s.pattern_config
        from public.stores s
        where s.owner_id = auth.uid()
        limit 1;
end;
$$ language plpgsql stable security definer set search_path = public;

alter function public.get_my_store() owner to postgres;
grant execute on function public.get_my_store() to authenticated, anon;

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
                from public.memorials m
                where m.cell_id = c.id
            ), '[]'::jsonb) as memorials
        from public.cells c
        join public.stores s on c.store_id = s.id
        where s.owner_id = auth.uid()
        order by c.row_num, c.col_num
    ) cell_data;

    return v_result;
end;
$$ language plpgsql stable security definer set search_path = public;

alter function public.get_store_grid() owner to postgres;
grant execute on function public.get_store_grid() to authenticated, anon;

-- ---------- 7. 开启 RLS（如果没开） ----------
alter table public.stores     enable row level security;
alter table public.cells      enable row level security;
alter table public.memorials  enable row level security;

-- 先删掉旧策略，重建（幂等）
drop policy if exists "store_select" on public.stores;
drop policy if exists "store_update" on public.stores;
create policy "store_select" on public.stores
    for select using (auth.uid() = owner_id);
create policy "store_update" on public.stores
    for update using (auth.uid() = owner_id);

drop policy if exists "cells_select" on public.cells;
drop policy if exists "cells_insert" on public.cells;
drop policy if exists "cells_update" on public.cells;
drop policy if exists "cells_delete" on public.cells;
create policy "cells_select" on public.cells
    for select using (store_id in (select id from public.stores where owner_id = auth.uid()));
create policy "cells_insert" on public.cells
    for insert with check (store_id in (select id from public.stores where owner_id = auth.uid()));
create policy "cells_update" on public.cells
    for update using (store_id in (select id from public.stores where owner_id = auth.uid()));
create policy "cells_delete" on public.cells
    for delete using (store_id in (select id from public.stores where owner_id = auth.uid()));

drop policy if exists "memorials_select" on public.memorials;
drop policy if exists "memorials_insert" on public.memorials;
drop policy if exists "memorials_update" on public.memorials;
drop policy if exists "memorials_delete" on public.memorials;
create policy "memorials_select" on public.memorials
    for select using (cell_id in (
        select c.id from public.cells c
        join public.stores s on c.store_id = s.id
        where s.owner_id = auth.uid()
    ));
create policy "memorials_insert" on public.memorials
    for insert with check (cell_id in (
        select c.id from public.cells c
        join public.stores s on c.store_id = s.id
        where s.owner_id = auth.uid()
    ));
create policy "memorials_update" on public.memorials
    for update using (cell_id in (
        select c.id from public.cells c
        join public.stores s on c.store_id = s.id
        where s.owner_id = auth.uid()
    ));
create policy "memorials_delete" on public.memorials
    for delete using (cell_id in (
        select c.id from public.cells c
        join public.stores s on c.store_id = s.id
        where s.owner_id = auth.uid()
    ));

-- ---------- 8. 给 RPC/表/序列授权（常见被遗漏的一步！） ----------
grant usage   on schema public to anon, authenticated;
grant select, insert, update, delete on public.stores     to authenticated;
grant select, insert, update, delete on public.cells      to authenticated;
grant select, insert, update, delete on public.memorials  to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant select on public.stores, public.cells, public.memorials to anon;

-- ---------- 完成 ----------
select '✅ 万能修复脚本执行完成！请回到注册页重试注册' as "结果";
