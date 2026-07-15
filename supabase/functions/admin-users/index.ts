// Função segura para o admin do CRM Instituto HH criar, resetar senha e excluir usuários.
// A chave-mestra do banco (SERVICE_ROLE_KEY) só existe aqui dentro — nunca no navegador.
import { createClient } from 'npm:@supabase/supabase-js@2';

const EMAIL_DOMAIN = 'instituto-hh.local';

Deno.serve(async (req) => {
  const cors = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, content-type',
  };
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(supabaseUrl, serviceRoleKey);

  try {
    const body = await req.json();
    const action = body.action;

    if (action === 'bootstrap') {
      // Único caminho sem exigir login prévio — e só funciona enquanto nenhum
      // usuário ainda tiver sido migrado para o Supabase Auth. Depois da primeira
      // migração, esta ação fica bloqueada para sempre (veja a checagem abaixo).
      const { count } = await admin
        .from('users')
        .select('id', { count: 'exact', head: true })
        .not('auth_user_id', 'is', null);
      if (count && count > 0) {
        return json({ error: 'Bootstrap já foi utilizado.' }, 403, cors);
      }
      const { userId, password } = body;
      if (!userId || !password || password.length < 8) {
        return json({ error: 'Dados incompletos ou senha curta demais.' }, 400, cors);
      }
      const { data: profile } = await admin.from('users').select('*').eq('id', userId).single();
      if (!profile) return json({ error: 'Usuário não encontrado.' }, 404, cors);
      const email = `${profile.login.toLowerCase()}@${EMAIL_DOMAIN}`;
      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
      });
      if (createErr) return json({ error: createErr.message }, 400, cors);
      const { error: linkErr } = await admin.from('users').update({ auth_user_id: created.user.id }).eq('id', userId);
      if (linkErr) return json({ error: linkErr.message }, 400, cors);
      return json({ ok: true }, 200, cors);
    }

    // 1) Todas as demais ações exigem login (precisa ser chamado por um admin já migrado)
    const authHeader = req.headers.get('Authorization') || '';
    const jwt = authHeader.replace('Bearer ', '');
    const { data: callerAuth, error: callerErr } = await admin.auth.getUser(jwt);
    if (callerErr || !callerAuth?.user) {
      return json({ error: 'Não autenticado.' }, 401, cors);
    }

    // 2) Confirma que quem está chamando é admin
    const { data: callerProfile } = await admin
      .from('users')
      .select('role')
      .eq('auth_user_id', callerAuth.user.id)
      .single();
    if (!callerProfile || callerProfile.role !== 'admin') {
      return json({ error: 'Apenas administradores podem gerenciar usuários.' }, 403, cors);
    }

    if (action === 'create') {
      const { name, login, password, role, closerId } = body;
      if (!name || !login || !password || password.length < 4) {
        return json({ error: 'Dados incompletos.' }, 400, cors);
      }
      const email = `${login.toLowerCase()}@${EMAIL_DOMAIN}`;
      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
      });
      if (createErr) return json({ error: createErr.message }, 400, cors);

      const { error: profileErr } = await admin.from('users').insert({
        id: crypto.randomUUID(),
        name, login: login.toLowerCase(), role, closer_id: closerId || null,
        auth_user_id: created.user.id,
      });
      if (profileErr) {
        await admin.auth.admin.deleteUser(created.user.id);
        return json({ error: profileErr.message }, 400, cors);
      }
      return json({ ok: true }, 200, cors);
    }

    if (action === 'resetPassword') {
      const { userId, password } = body;
      if (!password || password.length < 4) return json({ error: 'Senha muito curta.' }, 400, cors);
      const { data: profile } = await admin.from('users').select('auth_user_id').eq('id', userId).single();
      if (!profile?.auth_user_id) return json({ error: 'Usuário não encontrado.' }, 404, cors);
      const { error } = await admin.auth.admin.updateUserById(profile.auth_user_id, { password });
      if (error) return json({ error: error.message }, 400, cors);
      return json({ ok: true }, 200, cors);
    }

    if (action === 'attachAuth') {
      // Ativa o acesso de um perfil que existe na tabela "users" mas ainda não tem
      // login de verdade (ex: usuário restaurado de um backup antigo).
      const { userId, password } = body;
      if (!password || password.length < 6) return json({ error: 'Senha muito curta.' }, 400, cors);
      const { data: profile } = await admin.from('users').select('*').eq('id', userId).single();
      if (!profile) return json({ error: 'Usuário não encontrado.' }, 404, cors);
      if (profile.auth_user_id) return json({ error: 'Este usuário já tem acesso configurado.' }, 400, cors);
      const email = `${profile.login.toLowerCase()}@${EMAIL_DOMAIN}`;
      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
      });
      if (createErr) return json({ error: createErr.message }, 400, cors);
      const { error: linkErr } = await admin.from('users').update({ auth_user_id: created.user.id }).eq('id', userId);
      if (linkErr) return json({ error: linkErr.message }, 400, cors);
      return json({ ok: true }, 200, cors);
    }

    if (action === 'delete') {
      const { userId } = body;
      const { data: profile } = await admin.from('users').select('auth_user_id').eq('id', userId).single();
      await admin.from('users').delete().eq('id', userId);
      if (profile?.auth_user_id) await admin.auth.admin.deleteUser(profile.auth_user_id);
      return json({ ok: true }, 200, cors);
    }

    return json({ error: 'Ação desconhecida.' }, 400, cors);
  } catch (e) {
    return json({ error: String(e) }, 500, cors);
  }
});

function json(body: unknown, status: number, cors: Record<string, string>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}
