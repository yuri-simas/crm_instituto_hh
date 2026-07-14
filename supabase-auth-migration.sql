-- CRM Instituto HH — migração para login real via Supabase Auth
-- IMPORTANTE: NÃO rode este script ainda. Ele só deve ser executado depois que:
--   1) a função "admin-users" estiver publicada,
--   2) o usuário admin atual estiver migrado para o Supabase Auth,
--   3) o site (index.html) já estiver com o novo código de login.
-- Rodar antes disso vai travar o acesso de todo mundo (o app ainda usaria a chave anônima).
-- Rode no painel do Supabase: Database > SQL Editor > New query > Run.

-- 1) Liga cada linha da tabela "users" (perfil) a uma conta real do Supabase Auth
alter table users add column if not exists auth_user_id uuid unique references auth.users(id) on delete cascade;

-- 2) A senha deixa de ser guardada na nossa tabela — quem cuida disso agora é o Supabase Auth
alter table users alter column password_hash drop not null;

-- 3) Troca as políticas de acesso: de "qualquer um com a chave pública" (anon)
--    para "só quem fez login de verdade" (authenticated)
do $$
declare
  t text;
begin
  foreach t in array array['courses','payment_methods','closers','users','leads','lead_courses','meetings','sales','students','student_course_history']
  loop
    execute format('drop policy if exists anon_all on %I', t);
    execute format('drop policy if exists authenticated_all on %I', t);
    execute format('create policy authenticated_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- 4) Mesma troca para os contratos guardados no Storage
drop policy if exists anon_all_contracts on storage.objects;
drop policy if exists authenticated_all_contracts on storage.objects;
create policy authenticated_all_contracts on storage.objects
  for all to authenticated
  using (bucket_id = 'contracts')
  with check (bucket_id = 'contracts');

-- Nota: o bucket "contracts" continua marcado como público (para os links de download
-- funcionarem como hoje). Isso significa que quem tiver o link direto de um contrato específico
-- ainda consegue abri-lo sem login — mas não é mais possível listar ou adivinhar todos os
-- contratos sem estar autenticado. Uma proteção completa (links assinados, com validade) é uma
-- melhoria futura separada.
