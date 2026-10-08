// Voce cu salvare: fiecare text se generează o singură dată la ElevenLabs,
// apoi se păstrează în Supabase Storage (bucket public „voce”) și se refolosește.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Expose-Headers': 'x-voce-cache',
}
const BUCKET = 'voce'
const MAX_CHARS = 2500
// Câte caractere NOI (negăsite în cache) poate genera un utilizator pe zi. Se poate schimba din Secrets.
const LIMITA_ZI = Number(Deno.env.get('VOCE_LIMITA_ZI') ?? 20000)
// ID-urile (uuid) administratorilor care pot genera în masă din pagina ?admin=voce, fără limită.
const ADMINI = (Deno.env.get('VOCE_ADMINI') ?? '').split(',').map(s => s.trim()).filter(Boolean)
// Numele sub care poate fi salvată cheia ElevenLabs în Supabase → Edge Functions → Secrets
const KEY_NAMES = ['ELEVENLABS_API_KEY', 'ELEVEN_LABS_API_KEY', 'ELEVENLABS_KEY', 'ELEVEN_API_KEY', 'XI_API_KEY']

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

async function sha256hex(s: string): Promise<string> {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))
  return Array.from(new Uint8Array(h)).map(b => b.toString(16).padStart(2, '0')).join('')
}

const num = (v: unknown, d: number) => { const n = Number(v); return Number.isFinite(n) ? n : d }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  try {
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s*/i, '').trim()
    if (!token) return json({ error: 'Lipsește autentificarea' }, 401)

    const admin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } },
    )
    const { data: userData, error: userError } = await admin.auth.getUser(token)
    if (userError || !userData?.user) return json({ error: 'Token invalid' }, 401)

    const body = await req.json().catch(() => ({}))
    const text = String(body.text ?? '').trim()
    const voiceId = String(body.voice_id ?? '')
    const modelId = String(body.model_id ?? 'eleven_multilingual_v2')
    if (!text) return json({ error: 'Text gol' }, 400)
    if (text.length > MAX_CHARS) return json({ error: 'Text prea lung' }, 400)
    if (!/^[A-Za-z0-9]{10,40}$/.test(voiceId) || !/^[a-z0-9_]{3,60}$/.test(modelId)) return json({ error: 'Voce invalidă' }, 400)
    const s = body.voice_settings ?? {}
    // Ordinea câmpurilor trebuie să fie aceeași ca în aplicație (intră în cheia fișierului).
    const vs = {
      stability: num(s.stability, 0.55),
      similarity_boost: num(s.similarity_boost, 0.8),
      style: num(s.style, 0.2),
      use_speaker_boost: s.use_speaker_boost !== false,
    }
    const key = await sha256hex(`${voiceId}|${modelId}|${JSON.stringify(vs)}|${text}`)
    const path = `${key}.mp3`
    const store = admin.storage.from(BUCKET)

    // 1. Există deja?
    const { data: existing } = await store.download(path)
    if (existing) {
      return new Response(existing, { headers: { ...corsHeaders, 'Content-Type': 'audio/mpeg', 'x-voce-cache': 'hit' } })
    }

    // 2. Generează la ElevenLabs (doar în limita zilnică a utilizatorului)
    const apiKey = KEY_NAMES.map(n => Deno.env.get(n)).find(Boolean)
    if (!apiKey) { console.error('Lipsește cheia ElevenLabs în Secrets (' + KEY_NAMES.join(', ') + ')'); return json({ error: 'Vocea nu este disponibilă acum' }, 503) }
    if (!ADMINI.includes(userData.user.id)) {
      const { data: ok, error: eLim } = await admin.rpc('voce_rezerva', { uid: userData.user.id, n: text.length, limita: LIMITA_ZI })
      if (eLim) { console.error('voce_rezerva:', eLim.message); return json({ error: 'Vocea nu este disponibilă acum' }, 503) }
      if (!ok) return json({ error: 'Ai atins limita zilnică de voce. Mâine poți asculta din nou.' }, 429)
    }
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg' },
      body: JSON.stringify({ text, model_id: modelId, voice_settings: vs }),
    })
    if (!r.ok) {
      console.error('ElevenLabs', r.status, (await r.text()).slice(0, 300))
      return json({ error: 'Vocea nu este disponibilă acum' }, 502)
    }
    const audio = new Uint8Array(await r.arrayBuffer())

    // 3. Salvează (creează bucket-ul public la prima folosire)
    const up = () => store.upload(path, audio, { contentType: 'audio/mpeg', cacheControl: '31536000', upsert: true })
    let res = await up()
    if (res.error && /not.?found/i.test(res.error.message)) {
      await admin.storage.createBucket(BUCKET, { public: true })
      res = await up()
    }
    if (res.error) console.error('Storage upload:', res.error.message)

    return new Response(audio, {
      headers: { ...corsHeaders, 'Content-Type': 'audio/mpeg', 'x-voce-cache': res.error ? 'store-failed' : 'miss' },
    })
  } catch (err) {
    console.error('voce error:', err)
    return json({ error: 'Eroare internă' }, 500)
  }
})
