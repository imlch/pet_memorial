-- ============================================================
-- 宠物寄存格子管理系统 - Supabase 数据库初始化脚本
-- 执行顺序：先建表 -> 再建索引 -> 最后开 RLS + 策略
-- 在 Supabase 后台 -> SQL Editor 中粘贴运行即可
-- ============================================================

-- 启用 pgcrypto 扩展（用于 gen_random_uuid）
create extension if not exists "pgcrypto";

-- ============================================================
-- 1. 门店表 stores
-- ============================================================
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

comment on table public.stores is '门店信息表，每个账号对应一个门店';

-- ============================================================
-- 2. 格子数据表 cells
-- ============================================================
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

comment on table public.cells is '格子寄存信息表，每个门店每个格子一条记录';

-- ============================================================
-- 3. 纪念日表 memorials
-- ============================================================
create table if not exists public.memorials (
    id            uuid primary key default gen_random_uuid(),
    cell_id       uuid not null references public.cells(id) on delete cascade,
    label         text not null,
    memorial_date date not null,
    repeat_type   text not null default '每年',
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

comment on table public.memorials is '纪念日表，每个格子可配置多条纪念日';

-- ============================================================
-- 4. 索引优化
-- ============================================================
create index if not exists idx_stores_owner      on public.stores(owner_id);
create index if not exists idx_cells_store       on public.cells(store_id);
create index if not exists idx_cells_store_key   on public.cells(store_id, cell_key);
create index if not exists idx_memorials_cell    on public.memorials(cell_id);
create index if not exists idx_memorials_date    on public.memorials(memorial_date);

-- ============================================================
-- 5. 自动更新 updated_at 触发器
-- ============================================================
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

-- ============================================================
-- 6. 新用户注册后自动创建门店（RPC + Trigger）
-- ============================================================
create or replace function public.handle_new_user_create_store()
returns trigger as $$
declare
    store_name text;
begin
    store_name := coalesce(new.raw_user_meta_data ->> 'store_name', split_part(new.email, '@', 1) || '的门店');
    insert into public.stores (owner_id, name, rows_config, cols_config, pattern_config)
    values (new.id, store_name, 8, 15, '["small","small","large"]')
    on conflict (owner_id) do nothing;
    return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_auth_create_store on auth.users;

create trigger trg_auth_create_store
    after insert on auth.users
    for each row execute function public.handle_new_user_create_store();

-- ============================================================
-- 7. 行级安全 (RLS)
-- ============================================================
alter table public.stores     enable row level security;
alter table public.cells      enable row level security;
alter table public.memorials  enable row level security;

-- 7.1 stores 策略：用户只能访问自己的门店
drop policy if exists "store_select" on public.stores;
drop policy if exists "store_update" on public.stores;
create policy "store_select" on public.stores
    for select using (auth.uid() = owner_id);
create policy "store_update" on public.stores
    for update using (auth.uid() = owner_id);

-- 7.2 cells 策略：用户只能操作自己门店下的格子
drop policy if exists "cells_select" on public.cells;
drop policy if exists "cells_insert" on public.cells;
drop policy if exists "cells_update" on public.cells;
drop policy if exists "cells_delete" on public.cells;

create policy "cells_select" on public.cells
    for select using (
        store_id in (select id from public.stores where owner_id = auth.uid())
    );
create policy "cells_insert" on public.cells
    for insert with check (
        store_id in (select id from public.stores where owner_id = auth.uid())
    );
create policy "cells_update" on public.cells
    for update using (
        store_id in (select id from public.stores where owner_id = auth.uid())
    );
create policy "cells_delete" on public.cells
    for delete using (
        store_id in (select id from public.stores where owner_id = auth.uid())
    );

-- 7.3 memorials 策略：用户只能操作自己门店下的纪念日
drop policy if exists "memorials_select" on public.memorials;
drop policy if exists "memorials_insert" on public.memorials;
drop policy if exists "memorials_update" on public.memorials;
drop policy if exists "memorials_delete" on public.memorials;

create policy "memorials_select" on public.memorials
    for select using (
        cell_id in (
            select c.id from public.cells c
            join public.stores s on c.store_id = s.id
            where s.owner_id = auth.uid()
        )
    );
create policy "memorials_insert" on public.memorials
    for insert with check (
        cell_id in (
            select c.id from public.cells c
            join public.stores s on c.store_id = s.id
            where s.owner_id = auth.uid()
        )
    );
create policy "memorials_update" on public.memorials
    for update using (
        cell_id in (
            select c.id from public.cells c
            join public.stores s on c.store_id = s.id
            where s.owner_id = auth.uid()
        )
    );
create policy "memorials_delete" on public.memorials
    for delete using (
        cell_id in (
            select c.id from public.cells c
            join public.stores s on c.store_id = s.id
            where s.owner_id = auth.uid()
        )
    );

-- ============================================================
-- 8. RPC 函数：获取当前门店信息（前端调用）
-- ============================================================
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

comment on function public.get_my_store() is '获取当前登录用户的门店配置';

-- ============================================================
-- 9. RPC 函数：获取门店所有格子+纪念日（一次性返回减少请求）
-- ============================================================
create or replace function public.get_store_grid()
returns jsonb as $$
declare
    result jsonb;
begin
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

    return result;
end;
$$ language plpgsql stable security definer set search_path = public;

comment on function public.get_store_grid() is '获取门店所有格子及其纪念日（JSON一次性返回）';

-- ============================================================
-- 10. 种子数据（可选，用于演示；正式环境可注释掉）
-- ============================================================
-- （无需种子数据，用户自己录入即可）
