import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const num = (v: unknown) => {
  const n = Number(v)
  return Number.isFinite(n) && n >= 0 ? Math.round(n) : 0
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.replace(/^Bearer\s+/i, '').trim()
    if (!token || token === 'undefined' || token === 'null') {
      return json({ error: 'Lipsește tokenul de autentificare' }, 401)
    }

    // Service-role client: verifies the user token and writes past RLS
    const admin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } },
    )

    const { data: userData, error: userError } = await admin.auth.getUser(token)
    const user = userData?.user
    if (userError || !user) {
      return json({ error: 'Token invalid' }, 401)
    }

    const body = await req.json().catch(() => ({}))
    // Accept both shapes: { results: {...} } (sent by the app) or flat fields
    const r = body.results ?? body
    const corecte = num(r.correct ?? r.corecte)
    const gresite = num(r.wrong ?? r.gresite)
    const sarite = num(r.skipped ?? r.sarite)
    const total = num(r.total ?? r.nr_probleme) || corecte + gresite + sarite
    // Valori imposibile = cerere falsificată sau defectă: nu le salvăm.
    if (total > 200 || corecte + gresite + sarite > total) {
      return json({ error: 'Rezultate invalide' }, 400)
    }
    const durataSec = r.duration_sec != null
      ? num(r.duration_sec)
      : num(r.duration_mins) * 60
    const libraryId = typeof body.library_id === 'string' && body.library_id ? body.library_id : 'mixed'

    const row = {
      user_id: user.id,
      tip: 'antrenament',
      sursa: libraryId,
      library_id: libraryId,
      nr_probleme: total,
      corecte,
      gresite,
      sarite,
      scor: corecte,
      scor_maxim: total,
      durata_sec: durataSec,
      config: body.config && typeof body.config === 'object' ? body.config : {},
      problems: Array.isArray(body.problems) ? body.problems : [],
    }

    const { data, error } = await admin.from('sessions').insert(row).select().single()
    if (error) {
      console.error('DB error:', error)
      return json({ error: 'Sesiunea nu a putut fi salvată' }, 500)
    }

    return json({ success: true, session: data })
  } catch (err) {
    console.error('Unexpected error:', err)
    return json({ error: 'Eroare internă' }, 500)
  }
})
