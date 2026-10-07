-- ============================================================
-- Euclid Meditații — anunțuri de la profesor către clasă (doar în aplicație)
-- Rulează o singură dată în Supabase → SQL Editor.
-- Poate fi rulat din nou fără să strice nimic.
-- ============================================================

-- Anunțul unui profesor pentru o clasă. Doar profesorul clasei poate scrie; doar membrii o pot citi.
create table if not exists public.anunturi (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.classes(id) on delete cascade,
  teacher_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  titlu       text not null check (char_length(titlu) between 1 and 120),
  text        text not null default '' check (char_length(text) <= 1000),
  link        text check (link is null or link ~ '^https://'),
  creat_la    timestamptz not null default now()
);
alter table public.anunturi enable row level security;
drop policy if exists anunturi_citire on public.anunturi;
create policy anunturi_citire on public.anunturi for select to authenticated
  using (public.is_class_teacher(class_id) or public.is_class_member(class_id));
drop policy if exists anunturi_scriere on public.anunturi;
create policy anunturi_scriere on public.anunturi for insert to authenticated
  with check (teacher_id = auth.uid() and public.is_class_teacher(class_id));
grant select, insert on public.anunturi to authenticated;

-- Cine a citit fiecare anunț (fiecare elev vede doar propriile citiri).
create table if not exists public.anunturi_citite (
  user_id     uuid not null references auth.users(id) on delete cascade,
  anunt_id    uuid not null references public.anunturi(id) on delete cascade,
  citit_la    timestamptz not null default now(),
  primary key (user_id, anunt_id)
);
alter table public.anunturi_citite enable row level security;
drop policy if exists ac_propriu on public.anunturi_citite;
create policy ac_propriu on public.anunturi_citite for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert on public.anunturi_citite to authenticated;

-- Statistici pentru profesor: pentru fiecare anunț din clasă, câți membri l-au citit din câți.
create or replace function public.anunturi_statistici(cid uuid)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_class_teacher(cid) then
    raise exception 'Doar profesorul clasei poate vedea statisticile';
  end if;
  return (
    select coalesce(json_agg(x order by x.creat_la desc), '[]'::json)
    from (
      select a.id, a.titlu, a.text, a.link, a.creat_la,
             (select count(*) from public.anunturi_citite c
               where c.anunt_id = a.id
                 and exists (select 1 from public.class_members m
                             where m.class_id = cid and m.student_id = c.user_id))::int as citiri,
             (select count(*) from public.class_members m where m.class_id = cid)::int as membri
      from public.anunturi a
      where a.class_id = cid
    ) x
  );
end;
$$;

revoke all on function public.anunturi_statistici(uuid) from public, anon;
grant execute on function public.anunturi_statistici(uuid) to authenticated;
