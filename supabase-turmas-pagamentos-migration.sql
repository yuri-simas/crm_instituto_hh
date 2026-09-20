-- CRM Instituto HH — migração: turmas por curso + pagamentos parciais nas vendas
-- Rode este script inteiro uma vez no SQL Editor do painel Supabase (Database > SQL Editor > New query > Run).
-- Seguro rodar de novo: usa "if not exists" e a migração de dados só cria o que ainda não existe.
--
-- O que muda:
--   1) Nova tabela course_classes: cada curso pode ter várias turmas, com data, vagas e preço próprio (opcional).
--   2) sales ganha class_id (turma vendida), list_price (preço de tabela, para enxergar o desconto) e notes.
--   3) Nova tabela sale_payments: cada venda pode ter vários pagamentos (sinal, parcelas até o dia do curso).
--      O campo sales.value continua sendo o TOTAL negociado; o que foi pago é a soma de sale_payments.
--   4) Vendas já existentes são consideradas quitadas: recebem um pagamento único igual ao valor, na data da venda.

-- ========== 1) TURMAS ==========
create table if not exists course_classes (
  id text primary key,
  course_id text references courses(id) on delete cascade,
  name text not null,
  start_date date,
  end_date date,
  capacity integer default 0,
  price numeric,                      -- null = usa o preço padrão do curso
  created_at timestamptz default now()
);

-- ========== 2) VENDAS ==========
alter table sales add column if not exists class_id text references course_classes(id) on delete set null;
alter table sales add column if not exists list_price numeric;
alter table sales add column if not exists notes text;

-- ========== 3) PAGAMENTOS ==========
create table if not exists sale_payments (
  id text primary key,
  sale_id text references sales(id) on delete cascade,
  amount numeric not null default 0,
  date date,
  payment_method text references payment_methods(id) on delete set null,
  notes text,
  created_at timestamptz default now()
);
create index if not exists sale_payments_sale_id_idx on sale_payments(sale_id);
create index if not exists course_classes_course_id_idx on course_classes(course_id);

-- ========== RLS (mesmo padrão das outras tabelas: só usuários autenticados) ==========
alter table course_classes enable row level security;
alter table sale_payments enable row level security;

drop policy if exists authenticated_all on course_classes;
create policy authenticated_all on course_classes for all to authenticated using (true) with check (true);

drop policy if exists authenticated_all on sale_payments;
create policy authenticated_all on sale_payments for all to authenticated using (true) with check (true);

-- ========== 4) MIGRAÇÃO DE DADOS ==========
-- Vendas antigas ficam quitadas: um pagamento igual ao valor total, na data da venda, com a forma já cadastrada.
insert into sale_payments (id, sale_id, amount, date, payment_method, notes)
select 'mig-' || s.id, s.id, s.value, s.date, s.payment_method, 'Migração: venda anterior ao controle de pagamentos'
from sales s
where coalesce(s.value, 0) > 0
  and not exists (select 1 from sale_payments p where p.sale_id = s.id);

-- Preço de tabela das vendas antigas = preço atual do curso (só onde ainda estiver vazio).
update sales s
set list_price = c.price
from courses c
where s.course_id = c.id and s.list_price is null;
