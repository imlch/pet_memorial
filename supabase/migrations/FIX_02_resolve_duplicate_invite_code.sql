-- ============================================================
-- FIX_02_resolve_duplicate_invite_code.sql
-- 用途：解决 002 脚本执行报 "stores_invite_code_key 唯一约束冲突 (M57GER 已存在)" 问题
-- 根因：002 最初版本给老门店批量补邀请码时，没有做唯一性循环校验，
--       两家门店恰好 random() 生成了同一个 6 位码导致 23505 报错。
--
-- 执行方式：
--   ★ 先完整运行本脚本（SQL Editor 粘贴 -> Run）
--   ★ 然后再完整重新运行 002_add_staff_and_invite.sql
-- ============================================================

-- ---------- 步骤 0：创建「生成全局唯一邀请码」的 PL/pgSQL 辅助函数（幂等） ----------
create or replace function public.gen_unique_invite_code()
returns text as $$
declare
    v_chars  text  := 'ABCDEFGHJKMNPQRTUVWXYZ23456789';  -- 32 字符（去掉 I L O S 0 1）
    v_code   text;
    v_loops  int   := 0;
begin
    -- 死循环直到生成一个 stores 表里不存在的邀请码（理论上 32^6=1,073,741,824 种组合，几乎不会 >1 次冲突）
    loop
        v_loops := v_loops + 1;
        if v_loops > 500 then
            -- 极端兜底：7 位码
            select string_agg(substr(v_chars, (random() * (length(v_chars)-1) + 1)::int, 1), '')
              into v_code
              from generate_series(1,7);
        else
            select string_agg(substr(v_chars, (random() * (length(v_chars)-1) + 1)::int, 1), '')
              into v_code
              from generate_series(1,6);
        end if;

        exit when not exists (
            select 1 from public.stores where invite_code = v_code
        );
    end loop;
    return v_code;
end;
$$ language plpgsql volatile;

alter function public.gen_unique_invite_code() owner to postgres;
grant execute on function public.gen_unique_invite_code() to postgres, authenticated;

-- ---------- 步骤 1：如果 002 已经执行到一半，先把 stores.invite_code 列恢复到「可空 + 无任何唯一约束」 ----------
-- （因为 002 第一次 alter 时 inline 了 unique，即使事务回滚列也可能残留约束）
-- 粗暴兜底：去掉所有挂在 stores 表 invite_code 列上的唯一约束（无论任何命名）
do $$
declare r record;
begin
  for r in
    select c.conname
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.conrelid = 'public.stores'::regclass
      and c.contype = 'u'
      and a.attname = 'invite_code'
  loop
    execute 'alter table public.stores drop constraint if exists ' || quote_ident(r.conname);
  end loop;
end $$;

-- ---------- 步骤 2：加列（如果列还不存在就加上，确保安全） ----------
do $$
begin
    if not exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='stores' and column_name='invite_code'
    ) then
        alter table public.stores add column invite_code text;
    end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='stores' and column_name='created_by_email'
    ) then
        alter table public.stores add column created_by_email text;
    end if;
end $$;

-- ---------- 步骤 3：为 invite_code 为 NULL 或 重复 的门店，全部用 gen_unique_invite_code() 重新生成 ----------
-- 3.1 先把 NULL 的填上（这些是 002 还没执行到的「漏网」老门店）
update public.stores
   set invite_code       = public.gen_unique_invite_code(),
       created_by_email  = coalesce(created_by_email, (select u.email from auth.users u where u.id = stores.owner_id))
 where invite_code is null;

-- 3.2 再把重复的（count > 1 的）保留最早创建的 1 条，其它全部重生成
with dup as (
    select id,
           row_number() over (partition by invite_code order by created_at asc, id asc) as rn
      from public.stores
)
update public.stores s
   set invite_code = public.gen_unique_invite_code()
  from dup d
 where s.id = d.id
   and d.rn > 1;

-- ---------- 步骤 4：此时 invite_code 肯定全局唯一了，安全地加回唯一 + NOT NULL 约束 ----------
alter table public.stores alter column invite_code set not null;

do $$
begin
    if not exists (
        select 1 from pg_constraint
         where conname = 'stores_invite_code_key' and conrelid = 'public.stores'::regclass
    ) then
        alter table public.stores add constraint stores_invite_code_key unique (invite_code);
    end if;
end $$;

-- ---------- 完成 ----------
select '✅ 冲突修复完成！可以继续完整运行 002_add_staff_and_invite.sql' as "结果"
union all
select '当前门店数: ' || count(*)::text from public.stores
union all
select '唯一邀请码数: ' || count(distinct invite_code)::text from public.stores;
