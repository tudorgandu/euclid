-- ============================================================
-- Euclid Meditații — notificări despre calendarul concursurilor
-- Rulează o singură dată în Supabase → SQL Editor.
-- Poate fi rulat din nou fără să strice nimic.
-- ============================================================

-- Consimțământul pentru emailuri (implicit: nimeni nu primește emailuri până nu bifează).
alter table public.profiles add column if not exists notificari_email boolean not null default false;

-- Ultima versiune a calendarului văzută de funcția de sincronizare (ca să știe ce s-a schimbat).
create table if not exists public.calendar_snapshot (
  id          int primary key default 1 check (id = 1),
  continut    jsonb not null default '[]'::jsonb,
  actualizat  timestamptz not null default now()
);
alter table public.calendar_snapshot enable row level security;
revoke all on public.calendar_snapshot from anon, authenticated;

-- Notificările (aceleași pentru toți: elevi, părinți, profesori).
create table if not exists public.notificari (
  id        uuid primary key default gen_random_uuid(),
  tip       text not null default 'calendar',
  titlu     text not null,
  text      text not null default '',
  link      text,
  creat_la  timestamptz not null default now()
);
alter table public.notificari enable row level security;
drop policy if exists notificari_citire on public.notificari;
create policy notificari_citire on public.notificari for select to authenticated using (true);
grant select on public.notificari to authenticated;

-- Ce notificări a citit fiecare utilizator.
create table if not exists public.notificari_citite (
  user_id         uuid not null references auth.users(id) on delete cascade,
  notificare_id   uuid not null references public.notificari(id) on delete cascade,
  citit_la        timestamptz not null default now(),
  primary key (user_id, notificare_id)
);
alter table public.notificari_citite enable row level security;
drop policy if exists nc_propriu on public.notificari_citite;
create policy nc_propriu on public.notificari_citite for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert on public.notificari_citite to authenticated;

-- Cron zilnic (opțional, după ce ai pus funcția „sincronizeaza-calendar" în Supabase):
-- select cron.schedule('sincronizeaza-calendar', '0 7 * * *', $$
--   select net.http_post(
--     url := 'https://PROIECTUL_TAU.supabase.co/functions/v1/sincronizeaza-calendar',
--     headers := '{"x-cron-secret": "SECRETUL_TAU"}'::jsonb
--   );
-- $$);
