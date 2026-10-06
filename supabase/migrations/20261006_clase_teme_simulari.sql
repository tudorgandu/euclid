-- ============================================================
-- Euclid Meditații — clase, teme și simulări pe clasă
-- Rulează o singură dată în Supabase → SQL Editor.
-- Scriptul poate fi rulat din nou fără să strice nimic.
-- ============================================================

-- ── Tabele ──────────────────────────────────────────────────
create table if not exists public.classes (
  id          uuid primary key default gen_random_uuid(),
  teacher_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 80),
  join_code   text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists public.class_members (
  class_id     uuid not null references public.classes(id) on delete cascade,
  student_id   uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  joined_at    timestamptz not null default now(),
  primary key (class_id, student_id)
);

create table if not exists public.assignments (
  id           uuid primary key default gen_random_uuid(),
  class_id     uuid not null references public.classes(id) on delete cascade,
  kind         text not null check (kind in ('tema', 'simulare')),
  title        text not null check (char_length(title) between 1 and 120),
  description  text not null default '',
  problem_keys jsonb not null check (jsonb_typeof(problem_keys) = 'array'
                                     and jsonb_array_length(problem_keys) between 1 and 50),
  opens_at     timestamptz not null default now(),
  closes_at    timestamptz not null,
  created_at   timestamptz not null default now(),
  check (closes_at > opens_at)
);
create index if not exists assignments_class_idx on public.assignments(class_id);

create table if not exists public.submissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  student_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  answers       jsonb not null default '[]' check (jsonb_typeof(answers) = 'array'),
  correct       int not null default 0,
  total         int not null default 0,
  started_at    timestamptz,
  submitted_at  timestamptz not null default now(),
  unique (assignment_id, student_id)
);

-- ── Funcții ajutătoare (evită recursivitatea în regulile de acces) ──
create or replace function public.is_class_teacher(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.classes where id = cid and teacher_id = auth.uid());
$$;

create or replace function public.is_class_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.class_members where class_id = cid and student_id = auth.uid());
$$;

create or replace function public.assignment_class(aid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select class_id from public.assignments where id = aid;
$$;

-- Se poate preda: tema oricând după deschidere (întârzierea apare la profesor),
-- simularea doar până la ora de final + 3 minute toleranță.
create or replace function public.can_submit(aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.assignments a
    where a.id = aid
      and now() >= a.opens_at
      and (a.kind = 'tema' or now() <= a.closes_at + interval '3 minutes')
  );
$$;

-- Creează o clasă cu un cod unic de 6 caractere (fără litere ușor de confundat).
create or replace function public.create_class(class_name text) returns json
language plpgsql security definer set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
  new_id uuid;
begin
  if auth.uid() is null then raise exception 'Trebuie să fii autentificat'; end if;
  if char_length(trim(coalesce(class_name, ''))) = 0 then raise exception 'Scrie numele clasei'; end if;
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.classes where join_code = code);
  end loop;
  insert into public.classes (teacher_id, name, join_code)
  values (auth.uid(), left(trim(class_name), 80), code)
  returning id into new_id;
  return json_build_object('id', new_id, 'join_code', code);
end $$;

-- Elevul intră în clasă cu codul primit de la profesor.
create or replace function public.join_class(code text, student_name text) returns json
language plpgsql security definer set search_path = public as $$
declare c public.classes;
begin
  if auth.uid() is null then raise exception 'Trebuie să fii autentificat'; end if;
  if char_length(trim(coalesce(student_name, ''))) = 0 then raise exception 'Scrie-ți numele'; end if;
  select * into c from public.classes where join_code = upper(trim(code));
  if not found then raise exception 'Codul clasei nu este corect'; end if;
  insert into public.class_members (class_id, student_id, display_name)
  values (c.id, auth.uid(), left(trim(student_name), 60))
  on conflict (class_id, student_id) do update set display_name = excluded.display_name;
  return json_build_object('id', c.id, 'name', c.name);
end $$;

-- Problemele unei lucrări: profesorul le vede oricând, elevul doar de la ora de start.
create or replace function public.get_assignment_problems(aid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.assignments;
begin
  select * into a from public.assignments where id = aid;
  if not found then return null; end if;
  if public.is_class_teacher(a.class_id) then return a.problem_keys; end if;
  if public.is_class_member(a.class_id) and now() >= a.opens_at then return a.problem_keys; end if;
  return null;
end $$;

-- La predare, serverul fixează elevul și ora predării (nu se pot falsifica din browser).
create or replace function public.submissions_set_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.student_id   := auth.uid();
  new.submitted_at := now();
  return new;
end $$;

drop trigger if exists submissions_defaults on public.submissions;
create trigger submissions_defaults before insert on public.submissions
  for each row execute function public.submissions_set_defaults();

-- ── Reguli de acces (Row Level Security) ───────────────────
alter table public.classes       enable row level security;
alter table public.class_members enable row level security;
alter table public.assignments   enable row level security;
alter table public.submissions   enable row level security;

drop policy if exists classes_select on public.classes;
create policy classes_select on public.classes for select
  using (teacher_id = auth.uid() or public.is_class_member(id));
drop policy if exists classes_update on public.classes;
create policy classes_update on public.classes for update
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());
drop policy if exists classes_delete on public.classes;
create policy classes_delete on public.classes for delete
  using (teacher_id = auth.uid());

drop policy if exists members_select on public.class_members;
create policy members_select on public.class_members for select
  using (student_id = auth.uid() or public.is_class_teacher(class_id));
drop policy if exists members_delete on public.class_members;
create policy members_delete on public.class_members for delete
  using (student_id = auth.uid() or public.is_class_teacher(class_id));

drop policy if exists assignments_select on public.assignments;
create policy assignments_select on public.assignments for select
  using (public.is_class_teacher(class_id) or public.is_class_member(class_id));
drop policy if exists assignments_insert on public.assignments;
create policy assignments_insert on public.assignments for insert
  with check (public.is_class_teacher(class_id));
drop policy if exists assignments_update on public.assignments;
create policy assignments_update on public.assignments for update
  using (public.is_class_teacher(class_id)) with check (public.is_class_teacher(class_id));
drop policy if exists assignments_delete on public.assignments;
create policy assignments_delete on public.assignments for delete
  using (public.is_class_teacher(class_id));

drop policy if exists submissions_select on public.submissions;
create policy submissions_select on public.submissions for select
  using (student_id = auth.uid() or public.is_class_teacher(public.assignment_class(assignment_id)));
drop policy if exists submissions_insert on public.submissions;
create policy submissions_insert on public.submissions for insert
  with check (public.is_class_member(public.assignment_class(assignment_id))
              and public.can_submit(assignment_id));
drop policy if exists submissions_delete on public.submissions;
create policy submissions_delete on public.submissions for delete
  using (public.is_class_teacher(public.assignment_class(assignment_id)));

-- ── Drepturi ───────────────────────────────────────────────
-- Vizitatorii neautentificați nu au acces deloc.
revoke all on public.classes, public.class_members, public.assignments, public.submissions from anon;
revoke all on public.classes, public.class_members, public.assignments, public.submissions from authenticated;

grant select, update, delete on public.classes to authenticated;          -- crearea se face prin create_class
grant select, delete         on public.class_members to authenticated;    -- intrarea se face prin join_class
grant select (id, class_id, kind, title, description, opens_at, closes_at, created_at)
                             on public.assignments to authenticated;       -- problemele: prin get_assignment_problems
grant insert, update, delete on public.assignments to authenticated;
grant select, insert, delete on public.submissions to authenticated;
grant all on public.classes, public.class_members, public.assignments, public.submissions to service_role;

revoke execute on function public.is_class_teacher(uuid), public.is_class_member(uuid),
  public.assignment_class(uuid), public.can_submit(uuid), public.create_class(text),
  public.join_class(text, text), public.get_assignment_problems(uuid),
  public.submissions_set_defaults() from public, anon;
grant execute on function public.is_class_teacher(uuid), public.is_class_member(uuid),
  public.assignment_class(uuid), public.can_submit(uuid), public.create_class(text),
  public.join_class(text, text), public.get_assignment_problems(uuid) to authenticated;
