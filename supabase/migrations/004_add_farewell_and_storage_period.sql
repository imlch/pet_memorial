-- ============================================================
-- 004_add_farewell_and_storage_period.sql
-- 新增：告别日期 + 寄存期限
-- 前置要求：必须先运行过「建 handle_updated_at() 函数 + 绑定触发器」的通用脚本
--          （FIX_01_register_error_all.sql 或之前对话中给的幂等块）
--          否则最后一步 drop/create trigger 会报 42883。
-- ============================================================

-- 1. cells 表加 2 列：告别日期、寄存期限
alter table public.cells
    add column if not exists farewell_date  date;
alter table public.cells
    add column if not exists storage_period text;

comment on column public.cells.farewell_date is '告别日期（即死亡日期）。民俗规则：去世当天算第1天，头七=告别日+6天（间隔6天含去世当天），七七=告别日+48天（49天周期内）；自动生成头七~七七共7条仅一次纪念日';
comment on column public.cells.storage_period  is '寄存期限：七天 / 49天 / 一年。选定后按入住日期自动算到期日生成「寄存到期」提醒';

-- 2. 索引：按告别日期、寄存期限过滤
create index if not exists idx_cells_farewell_date    on public.cells(farewell_date);
create index if not exists idx_cells_storage_period   on public.cells(storage_period);

-- 3. 重建 cells 表的 updated_at 触发器（加列后保持原行为）
--    ⚠️ 若此处报错 function public.handle_updated_at() does not exist（42883），
--       请先运行 FIX_01_register_error_all.sql 或单独执行以下最小建函数块：
--       create or replace function public.handle_updated_at() returns trigger language plpgsql as $$
--       begin new.updated_at = now(); return new; end; $$;
drop trigger if exists set_cells_updated_at on public.cells;
create trigger set_cells_updated_at
    before update on public.cells
    for each row execute function public.handle_updated_at();

-- 4. 可选：如果已经有历史 owner_name 数据，想一次性回填到 owner_responsible（003 漏跑的话），可取消注释执行
-- update public.cells set owner_responsible = owner_name where owner_responsible is null and owner_name is not null;

select '🎉 004 执行完成：cells 表已新增 farewell_date 和 storage_period 两列。
⚠️  后续步骤：请重新执行一次 FIX_05_sync_perf_and_staff_bugs.sql（因为 get_store_grid 的 select 列表需
把这两列也选出来，否则前端同步后这两个字段会被清空！）' as "执行结果";
