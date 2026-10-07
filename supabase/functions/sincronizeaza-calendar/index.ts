// Sincronizează calendarul concursurilor: compară data/calendar.json (din GitHub) cu ultima versiune văzută,
// creează notificările din aplicație și trimite emailuri celor care au bifat opțiunea.
// Apelată zilnic de pg_cron (vezi migrarea 20261007_notificari.sql). Necesită:
//   CRON_SECRET, RESEND_API_KEY, NOTIFICARI_FROM (ex. "Euclid <notificari@domeniul-tau.ro>"),
//   opțional APP_URL (implicit https://tudorgandu.github.io/euclid/).
// SUPABASE_URL și SUPABASE_SERVICE_ROLE_KEY sunt puse automat de Supabase.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const CALENDAR_URL = 'https://raw.githubusercontent.com/tudorgandu/euclid/main/data/calendar.json';
const APP_URL = Deno.env.get('APP_URL') || 'https://tudorgandu.github.io/euclid/';

// Câmpurile a căror schimbare contează pentru elevi (restul, ca verificat_la, nu produc notificare).
const CAMPURI = ['nume', 'scoala', 'oras', 'clase', 'data', 'data_text', 'status', 'site', 'link_inscriere', 'inscriere'];
const ETICHETE: Record<string, string> = {
  nume: 'nume', scoala: 'școala', oras: 'orașul', clase: 'clasele', data: 'data', data_text: 'data',
  status: 'statusul', site: 'site-ul', link_inscriere: 'linkul de înscriere', inscriere: 'perioada de înscriere',
};

type Intrare = Record<string, any>;

function diferente(vechi: Intrare, nou: Intrare): string[] {
  const out: string[] = [];
  for (const c of CAMPURI) {
    if (JSON.stringify(vechi[c] ?? null) !== JSON.stringify(nou[c] ?? null)) out.push(ETICHETE[c] || c);
  }
  return [...new Set(out)];
}

function notificariDinSchimbari(vechi: Intrare[], nou: Intrare[]) {
  const map = new Map(vechi.map(e => [e.id, e]));
  const rez: { titlu: string; text: string; link: string | null }[] = [];
  for (const e of nou) {
    if (e.status !== 'publicat') continue;             // doar ce e publicat ajunge la elevi
    const v = map.get(e.id);
    const link = /^https:\/\//.test(e.site || '') ? e.site : null;
    if (!v || v.status !== 'publicat') {
      rez.push({ titlu: `Concurs nou în calendar: ${e.nume}`,
                 text: `${e.scoala || ''}${e.oras ? ', ' + e.oras : ''}. ${e.data_text || ''}`.trim(), link });
    } else {
      const d = diferente(v, e);
      if (d.length) rez.push({ titlu: `S-a schimbat: ${e.nume}`,
                               text: `Au fost actualizate ${d.join(', ')}. ${e.data_text || ''}`.trim(), link });
    }
  }
  return rez;
}

function emailHtml(titlu: string, text: string, link: string | null) {
  const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
  return `<div style="font-family:system-ui,sans-serif;font-size:16px;line-height:1.5;color:#1B3F6B">
    <h2 style="margin:0 0 .5rem">${esc(titlu)}</h2>
    <p>${esc(text)}</p>
    ${link ? `<p><a href="${esc(link)}">Vezi detalii</a></p>` : ''}
    <p><a href="${APP_URL}">Deschide Euclid Meditații</a></p>
    <hr style="border:none;border-top:1px solid #ddd">
    <p style="font-size:13px;color:#666">Primești acest email pentru că ai activat notificările despre calendarul concursurilor.
    Le poți dezactiva oricând din secțiunea „Notificări” a aplicației.</p>
  </div>`;
}

Deno.serve(async (req) => {
  if (req.headers.get('x-cron-secret') !== Deno.env.get('CRON_SECRET')) {
    return new Response('neautorizat', { status: 401 });
  }
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });

  const r = await fetch(CALENDAR_URL, { cache: 'no-store' });
  if (!r.ok) return Response.json({ eroare: 'nu pot citi calendarul', status: r.status }, { status: 502 });
  const calendar = await r.json();
  const nou: Intrare[] = calendar.intrari || [];

  const { data: snap, error: eSnap } = await sb.from('calendar_snapshot').select('continut').eq('id', 1).maybeSingle();
  if (eSnap) return Response.json({ eroare: eSnap.message }, { status: 500 });

  // Prima rulare: doar reținem starea curentă, fără notificări către toți.
  if (!snap) {
    await sb.from('calendar_snapshot').upsert({ id: 1, continut: nou, actualizat: new Date().toISOString() });
    return Response.json({ initializare: true, intrari: nou.length });
  }

  const schimbari = notificariDinSchimbari(snap.continut || [], nou);
  if (!schimbari.length) return Response.json({ schimbari: 0 });

  const { error: eIns } = await sb.from('notificari').insert(schimbari.map(s => ({ tip: 'calendar', ...s })));
  if (eIns) return Response.json({ eroare: eIns.message }, { status: 500 });

  // Emailuri: doar utilizatorii care au bifat opțiunea.
  let trimise = 0;
  const key = Deno.env.get('RESEND_API_KEY');
  if (key) {
    const { data: opt } = await sb.from('profiles').select('id').eq('notificari_email', true);
    const emailuri: string[] = [];
    for (const p of opt || []) {
      const { data: u } = await sb.auth.admin.getUserById(p.id);
      if (u?.user?.email) emailuri.push(u.user.email);
    }
    for (const s of schimbari) {
      for (let i = 0; i < emailuri.length; i += 100) {            // Resend: maximum 100 per lot
        const lot = emailuri.slice(i, i + 100).map(to => ({
          from: Deno.env.get('NOTIFICARI_FROM'), to: [to], subject: s.titlu,
          html: emailHtml(s.titlu, s.text, s.link),
        }));
        const res = await fetch('https://api.resend.com/emails/batch', {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(lot),
        });
        if (res.ok) trimise += lot.length;
        else console.error('Resend', res.status, await res.text());
      }
    }
  }

  await sb.from('calendar_snapshot').upsert({ id: 1, continut: nou, actualizat: new Date().toISOString() });
  return Response.json({ schimbari: schimbari.length, emailuriTrimise: trimise });
});
