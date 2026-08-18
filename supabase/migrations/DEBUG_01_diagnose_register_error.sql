-- ============================================================
-- 诊断脚本：Database error saving new user - 一键排查
-- 使用方法：复制全文到 Supabase SQL Editor -> Run
-- 看下方 4 个结果集，发给我或自己对照 README
-- ============================================================

-- 🔍 检查项 1：pgcrypto 扩展是否已启用，gen_random_uuid() 是否可用
select
  '检查 pgcrypto 扩展 + gen_random_uuid()' as "检查项",
  case
    when exists (select 1 from pg_extension where extname = 'pgcrypto')
    then '✅ pgcrypto 已安装'
    else '❌ pgcrypto 未安装！请运行修复脚本 1'
  end as "结果"
union all
select
  'gen_random_uuid() 函数是否可调用' as "检查项",
  (select case when gen_random_uuid() is not null
    then '✅ 函数可用，返回: ' || gen_random_uuid()::text
    else '❌ 函数不可用' end) as "结果";

-- 🔍 检查项 2：stores / cells / memorials 三张表是否真的存在
select
  case when tablename = 'stores'     then '✅ stores 表存在'
       when tablename = 'cells'      then '✅ cells 表存在'
       when tablename = 'memorials'  then '✅ memorials 表存在'
       else '⚠️  未知表: ' || tablename
  end as "表检查结果",
  rowcount as "当前行数"
from (
  select 'stores'     as tablename, count(*)::text as rowcount from information_schema.tables where table_schema='public' and table_name='stores'
  union all
  select 'cells'      as tablename, count(*)::text as rowcount from information_schema.tables where table_schema='public' and table_name='cells'
  union all
  select 'memorials'  as tablename, count(*)::text as rowcount from information_schema.tables where table_schema='public' and table_name='memorials'
) t;

-- 🔍 检查项 3：两个 RPC 函数是否存在
select
  case when proname = 'get_my_store'     then '✅ RPC: get_my_store 存在'
       when proname = 'get_store_grid'   then '✅ RPC: get_store_grid 存在'
       else '❌ 缺少 RPC 函数: ' || proname
  end as "RPC 函数检查",
  pg_get_functiondef(p.oid) as "函数定义摘要(只看是否存在即可)"
from pg_proc p
join pg_namespace n on p.pronamespace = n.oid
where n.nspname = 'public' and p.proname in ('get_my_store', 'get_store_grid');

-- 🔍 检查项 4：触发器函数 + auth.users 触发器是否真正挂好
select
  '触发器函数 handle_new_user_create_store 是否存在' as "检查项",
  case when exists (
    select 1 from pg_proc p join pg_namespace n on p.pronamespace=n.oid
    where n.nspname='public' and p.proname='handle_new_user_create_store'
  ) then '✅ 触发器函数存在' else '❌ 触发器函数不存在！请重新创建' end as "结果"
union all
select
  'auth.users 上是否挂了 trg_auth_create_store 触发器' as "检查项",
  case when exists (
    select 1
    from pg_trigger t
    join pg_class   c on t.tgrelid = c.oid
    join pg_namespace n on c.relnamespace = n.oid
    where n.nspname = 'auth'
      and c.relname = 'users'
      and t.tgname  = 'trg_auth_create_store'
  ) then '✅ 触发器已绑定到 auth.users' else '❌ auth.users 上没有触发器！注册不会创建门店' end as "结果"
union all
select
  '触发器函数 set_updated_at 是否存在' as "检查项",
  case when exists (
    select 1 from pg_proc p join pg_namespace n on p.pronamespace=n.oid
    where n.nspname='public' and p.proname='set_updated_at'
  ) then '✅ 存在' else '⚠️  不存在(不影响注册，只影响 updated_at)' end as "结果";

-- 🔍 检查项 5：RLS 是否已开启（不影响注册，但影响后续读写）
select
  relname as "表名",
  case when relrowsecurity then '✅ 已开启 RLS' else '⚠️  未开启 RLS（门店可能互相看到数据）' end as "RLS状态"
from pg_class c
join pg_namespace n on c.relnamespace = n.oid
where n.nspname='public' and c.relname in ('stores','cells','memorials');
