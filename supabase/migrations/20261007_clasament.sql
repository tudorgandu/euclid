-- ============================================================
-- Euclid Meditații — clasament pe clasă (puncte = răspunsuri corecte)
-- Rulează o singură dată în Supabase → SQL Editor.
-- Poate fi rulat din nou fără să strice nimic.
-- ============================================================
-- Punctele unui elev = răspunsurile corecte din toate sesiunile de antrenament
-- (inclusiv problema zilei) + răspunsurile corecte din temele și simulările clasei.
-- Funcția verifică întâi că cel care întreabă este elev sau profesor în clasa respectivă.

create or replace function public.get_leaderboard(cid uuid, since timestamptz default null)
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.is_class_teacher(cid) or public.is_class_member(cid)) then
    raise exception 'Nu ai acces la clasamentul acestei clase';
  end if;

  return (
    select coalesce(json_agg(x order by x.points desc, x.display_name), '[]'::json)
    from (
      select m.display_name,
             (m.student_id = auth.uid()) as is_me,
             (
               coalesce((select sum(s.corecte) from public.sessions s
                          where s.user_id = m.student_id
                            and (since is null or s.created_at >= since)), 0)
             + coalesce((select sum(b.correct) from public.submissions b
                          join public.assignments a on a.id = b.assignment_id
                          where a.class_id = cid
                            and b.student_id = m.student_id
                            and (since is null or b.submitted_at >= since)), 0)
             )::int as points
      from public.class_members m
      where m.class_id = cid
    ) x
  );
end;
$$;

revoke all on function public.get_leaderboard(uuid, timestamptz) from public, anon;
grant execute on function public.get_leaderboard(uuid, timestamptz) to authenticated;
