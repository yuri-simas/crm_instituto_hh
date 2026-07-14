-- CRM Instituto HH — schema Supabase
-- Rode este script inteiro uma vez no SQL Editor do painel Supabase (Database > SQL Editor > New query > Run).
-- Seguro rodar de novo: usa "if not exists" / "or replace" onde possível.

-- ========== TABELAS ==========

create table if not exists courses (
  id text primary key,
  name text not null,
  price numeric default 0,
  template_file_path text,
  template_file_name text,
  template_file_size integer,
  created_at timestamptz default now()
);

create table if not exists payment_methods (
  id text primary key,
  name text not null
);

create table if not exists closers (
  id text primary key,
  name text not null,
  commission_percent numeric default 0,
  accelerator_threshold numeric default 0,
  accelerator_percent numeric default 0
);

create table if not exists users (
  id text primary key,
  name text not null,
  login text not null unique,
  password_hash text not null,
  role text not null check (role in ('admin','closer')),
  closer_id text references closers(id) on delete set null
);

create table if not exists leads (
  id text primary key,
  name text not null,
  phone text,
  city_state text,
  education text,
  semester text,
  closer_id text references closers(id) on delete set null,
  date_assigned date,
  next_contact_date date,
  status text,
  notes text
);

create table if not exists lead_courses (
  lead_id text references leads(id) on delete cascade,
  course_id text references courses(id) on delete cascade,
  primary key (lead_id, course_id)
);

create table if not exists meetings (
  id text primary key,
  lead_id text references leads(id) on delete cascade,
  closer_id text references closers(id) on delete set null,
  scheduled_date date,
  status text,
  notes text
);

create table if not exists sales (
  id text primary key,
  student_name text,
  lead_id text references leads(id) on delete set null,
  course_id text references courses(id) on delete set null,
  closer_id text references closers(id) on delete set null,
  value numeric default 0,
  payment_method text references payment_methods(id) on delete set null,
  date date
);

create table if not exists students (
  id text primary key,
  name text not null,
  phone text,
  email text,
  cpf text,
  professional_registration text,
  cep text,
  address text
);

create table if not exists student_course_history (
  id text primary key,
  student_id text references students(id) on delete cascade,
  course_id text references courses(id) on delete set null,
  payment_method text references payment_methods(id) on delete set null,
  sale_id text references sales(id) on delete set null,
  date date,
  contract_file_path text,
  contract_file_name text,
  contract_file_size integer
);

-- ========== RLS ==========
-- Sem Supabase Auth: o app usa login/senha próprios validados contra a tabela `users`.
-- Todas as chamadas do navegador usam a chave "anon", então as policies abaixo liberam
-- select/insert/update/delete para o role anon em todas as tabelas. Isso reproduz o mesmo
-- nível de proteção que o app já tinha (só na interface) — quem tiver a URL + anon key
-- consegue ler/escrever os dados diretamente pela API. Ver nota de segurança combinada com o usuário.

alter table courses enable row level security;
alter table payment_methods enable row level security;
alter table closers enable row level security;
alter table users enable row level security;
alter table leads enable row level security;
alter table lead_courses enable row level security;
alter table meetings enable row level security;
alter table sales enable row level security;
alter table students enable row level security;
alter table student_course_history enable row level security;

drop policy if exists anon_all on courses;
create policy anon_all on courses for all to anon using (true) with check (true);

drop policy if exists anon_all on payment_methods;
create policy anon_all on payment_methods for all to anon using (true) with check (true);

drop policy if exists anon_all on closers;
create policy anon_all on closers for all to anon using (true) with check (true);

drop policy if exists anon_all on users;
create policy anon_all on users for all to anon using (true) with check (true);

drop policy if exists anon_all on leads;
create policy anon_all on leads for all to anon using (true) with check (true);

drop policy if exists anon_all on lead_courses;
create policy anon_all on lead_courses for all to anon using (true) with check (true);

drop policy if exists anon_all on meetings;
create policy anon_all on meetings for all to anon using (true) with check (true);

drop policy if exists anon_all on sales;
create policy anon_all on sales for all to anon using (true) with check (true);

drop policy if exists anon_all on students;
create policy anon_all on students for all to anon using (true) with check (true);

drop policy if exists anon_all on student_course_history;
create policy anon_all on student_course_history for all to anon using (true) with check (true);

-- ========== STORAGE (contratos) ==========

insert into storage.buckets (id, name, public)
values ('contracts', 'contracts', true)
on conflict (id) do update set public = true;

drop policy if exists anon_all_contracts on storage.objects;
create policy anon_all_contracts on storage.objects
  for all to anon
  using (bucket_id = 'contracts')
  with check (bucket_id = 'contracts');
