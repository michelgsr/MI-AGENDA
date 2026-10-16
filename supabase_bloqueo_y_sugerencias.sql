-- Pega TODO esto en Supabase > SQL Editor > New query > Run (una sola vez)

-- 1) Emails bloqueados (no pueden volver a crear cuenta)
create table if not exists public.blocked_emails(
  email text primary key,
  reason text,
  blocked_by uuid,
  blocked_at timestamptz not null default now()
);
alter table public.blocked_emails enable row level security;

create or replace function public.block_signup() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.email is not null and exists(select 1 from public.blocked_emails b where b.email=lower(new.email)) then
    raise exception 'email_blocked' using errcode='P0001';
  end if;
  return new;
end $$;
drop trigger if exists block_signup_trg on auth.users;
create trigger block_signup_trg before insert on auth.users for each row execute function public.block_signup();

create or replace function public.admin_blocked_list() returns setof public.blocked_emails
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.admins where user_id=auth.uid()) then raise exception 'forbidden'; end if;
  return query select * from public.blocked_emails order by blocked_at desc;
end $$;
create or replace function public.admin_unblock(p_email text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.admins where user_id=auth.uid()) then raise exception 'forbidden'; end if;
  delete from public.blocked_emails where email=lower(trim(p_email));
end $$;
revoke all on function public.admin_blocked_list(), public.admin_unblock(text) from public, anon;
grant execute on function public.admin_blocked_list(), public.admin_unblock(text) to authenticated;

-- 2) Buzón de sugerencias y errores
create table if not exists public.feedback(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  email text, name text,
  kind text not null default 'sugerencia' check (kind in ('sugerencia','error','otro')),
  message text not null check (char_length(message) between 3 and 2000),
  status text not null default 'nuevo' check (status in ('nuevo','leido','resuelto')),
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;
drop policy if exists fb_insert on public.feedback;
drop policy if exists fb_select_own on public.feedback;
drop policy if exists fb_admin_select on public.feedback;
drop policy if exists fb_admin_update on public.feedback;
drop policy if exists fb_admin_delete on public.feedback;
create policy fb_insert on public.feedback for insert to authenticated with check (user_id=auth.uid());
create policy fb_select_own on public.feedback for select to authenticated using (user_id=auth.uid());
create policy fb_admin_select on public.feedback for select to authenticated using (exists(select 1 from public.admins a where a.user_id=auth.uid()));
create policy fb_admin_update on public.feedback for update to authenticated using (exists(select 1 from public.admins a where a.user_id=auth.uid())) with check (exists(select 1 from public.admins a where a.user_id=auth.uid()));
create policy fb_admin_delete on public.feedback for delete to authenticated using (exists(select 1 from public.admins a where a.user_id=auth.uid()));
create or replace function public.fb_limit() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if (select count(*) from public.feedback where user_id=new.user_id and created_at>now()-interval '1 day')>=10 then raise exception 'fb_limit'; end if;
  return new;
end $$;
drop trigger if exists fb_limit_trg on public.feedback;
create trigger fb_limit_trg before insert on public.feedback for each row execute function public.fb_limit();
create index if not exists feedback_created_idx on public.feedback(created_at desc);
