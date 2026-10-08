-- ============================================================
-- Euclid Meditații — limită zilnică pentru vocea generată (ElevenLabs)
-- Rulează o singură dată în Supabase → SQL Editor.
-- Poate fi rulat din nou fără să strice nimic.
-- ============================================================
-- Doar textele noi (care nu sunt deja salvate) costă bani. Fiecare utilizator are un plafon
-- de caractere noi pe zi; funcția „voce” îl verifică înainte să ceară audio de la ElevenLabs.

create table if not exists public.voce_utilizare (
  user_id     uuid not null references auth.users(id) on delete cascade,
  zi          date not null default current_date,
  caractere   int  not null default 0,
  primary key (user_id, zi)
);
alter table public.voce_utilizare enable row level security;
revoke all on public.voce_utilizare from anon, authenticated;   -- doar funcția de pe server o folosește

-- Rezervă atomic n caractere pentru utilizator; întoarce false dacă s-ar depăși limita zilnică.
create or replace function public.voce_rezerva(uid uuid, n int, limita int)
returns boolean
language plpgsql security definer set search_path = public as $$
declare folosit int;
begin
  if n <= 0 then return true; end if;
  insert into public.voce_utilizare as v (user_id, zi, caractere)
    values (uid, current_date, n)
    on conflict (user_id, zi) do update set caractere = v.caractere + excluded.caractere
    where v.caractere + excluded.caractere <= limita
    returning caractere into folosit;
  if folosit is null then return false; end if;      -- actualizarea a fost refuzată de condiție
  if folosit > limita then                            -- primul apel al zilei, deja peste limită
    update public.voce_utilizare set caractere = caractere - n where user_id = uid and zi = current_date;
    return false;
  end if;
  return true;
end $$;

revoke all on function public.voce_rezerva(uuid, int, int) from public, anon, authenticated;
grant execute on function public.voce_rezerva(uuid, int, int) to service_role;
