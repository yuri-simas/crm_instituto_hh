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

-- ========== 5) MATRÍCULAS MANUAIS EM TURMA ==========
-- Além das vendas vinculadas à turma, o admin pode matricular uma aluna manualmente (sem venda).
create table if not exists class_enrollments (
  id text primary key,
  class_id text references course_classes(id) on delete cascade,
  student_id text references students(id) on delete cascade,
  notes text,
  created_at timestamptz default now()
);
create index if not exists class_enrollments_class_id_idx on class_enrollments(class_id);
alter table class_enrollments enable row level security;
drop policy if exists authenticated_all on class_enrollments;
create policy authenticated_all on class_enrollments for all to authenticated using (true) with check (true);

-- ========== 6) COMISSÃO DIVIDIDA ENTRE DOIS CLOSERS ==========
-- closer2_id: segundo closer (opcional). split_percent: parte do closer 1 em % (100 = sem divisão).
alter table sales add column if not exists closer2_id text references closers(id) on delete set null;
alter table sales add column if not exists split_percent numeric default 100;

-- ========== 7) VÁRIOS TELEFONES POR ALUNA ==========
-- students.phones guarda a lista; students.phone continua sendo o principal (primeiro da lista).
alter table students add column if not exists phones text[] default '{}';
update students set phones = array[phone] where (phones is null or cardinality(phones)=0) and coalesce(phone,'')<>'';

-- ========== 8) COMISSÃO POR CURSO ==========
-- O percentual de comissão passa a ser do curso (courses.commission_percent).
-- Os campos de comissão/acelerador em closers ficam na tabela por compatibilidade, mas não são mais usados.
alter table courses add column if not exists commission_percent numeric default 0;

-- ========== 9) PAGAMENTO DE COMISSÕES ==========
-- Cada repasse de comissão a um closer vira uma linha; o saldo em aberto é
-- (comissão gerada pelas vendas) - (soma dos pagamentos).
create table if not exists commission_payments (
  id text primary key,
  closer_id text references closers(id) on delete cascade,
  amount numeric not null default 0,
  date date,
  notes text,
  created_at timestamptz default now()
);
create index if not exists commission_payments_closer_id_idx on commission_payments(closer_id);
alter table commission_payments enable row level security;
drop policy if exists authenticated_all on commission_payments;
create policy authenticated_all on commission_payments for all to authenticated using (true) with check (true);

-- ========== 10) NOTA FISCAL POR ALUNA NA TURMA ==========
-- Marca se a NF daquela aluna já foi emitida. Fica na venda quando a aluna entrou por venda,
-- e na matrícula manual quando não há venda vinculada.
alter table sales add column if not exists nf_issued boolean default false;
alter table class_enrollments add column if not exists nf_issued boolean default false;

-- ========== 11) CUSTOS POR TURMA ==========
-- Cada turma pode ter custos próprios (aluguel, coffee break, material...).
-- O lucro da turma = receita das vendas - comissões dos closers - soma destes custos.
create table if not exists class_costs (
  id text primary key,
  class_id text references course_classes(id) on delete cascade,
  description text,
  amount numeric not null default 0,
  date date,
  created_at timestamptz default now()
);
create index if not exists class_costs_class_id_idx on class_costs(class_id);
alter table class_costs enable row level security;
drop policy if exists authenticated_all on class_costs;
create policy authenticated_all on class_costs for all to authenticated using (true) with check (true);

-- ========== 12) CUSTOS E IMPOSTOS POR VENDA ==========
-- Taxas de forma de pagamento, impostos e custos operacionais lançados na própria venda.
-- mode: 'valor' (valor fixo) | 'pct_venda' (% do valor negociado) | 'pct_forma' (% do que for pago numa forma).
create table if not exists sale_costs (
  id text primary key,
  sale_id text references sales(id) on delete cascade,
  kind text not null default 'operacional',
  description text,
  mode text not null default 'valor',
  percent numeric,
  payment_method text references payment_methods(id) on delete set null,
  amount numeric not null default 0,
  created_at timestamptz default now()
);
create index if not exists sale_costs_sale_id_idx on sale_costs(sale_id);
alter table sale_costs enable row level security;
drop policy if exists authenticated_all on sale_costs;
create policy authenticated_all on sale_costs for all to authenticated using (true) with check (true);

-- ========== 13) PREVISÃO DE PAGAMENTO ==========
-- Um lançamento passa a ser 'recebido' (dinheiro que entrou) ou 'previsto' (combinado com a aluna).
-- Só os recebidos contam como pago; os previstos viram lembrete de cobrança.
alter table sale_payments add column if not exists status text not null default 'recebido';
-- Lançamentos com data futura eram, na prática, parcelas combinadas: passam a ser previsões.
update sale_payments set status = 'previsto' where status = 'recebido' and date > current_date;

-- ========== 14) BASE DO PERCENTUAL DO CUSTO ==========
-- mode ganha 'pct_recebido' (% do que já entrou) e 'pct_base' (% de um valor informado).
alter table sale_costs add column if not exists base_amount numeric;

-- ========== 15) FLUXO DE CAIXA ==========
-- Prazo de compensação por forma de pagamento: Pix cai no mesmo dia, cartão em D+30 por parcela.
alter table payment_methods add column if not exists settlement_days integer default 0;
update payment_methods set settlement_days = 30 where name ilike '%cart%' and coalesce(settlement_days,0) = 0;

-- Parcelamento negociado no lançamento (1 = à vista).
alter table sale_payments add column if not exists installments integer default 1;

-- A taxa pode ser vinculada ao lançamento a que se refere, para a parcela entrar líquida no fluxo.
alter table sale_costs add column if not exists payment_id text references sale_payments(id) on delete set null;

-- Lançamentos manuais do fluxo: despesas que não são de turma (luz, guia de imposto) e outras entradas.
create table if not exists cash_entries (
  id text primary key,
  kind text not null default 'despesa',
  description text,
  category text,
  amount numeric not null default 0,
  due_date date,
  paid_date date,
  recurring boolean default false,
  notes text,
  created_at timestamptz default now()
);
create index if not exists cash_entries_due_idx on cash_entries(due_date);
alter table cash_entries enable row level security;
drop policy if exists authenticated_all on cash_entries;
create policy authenticated_all on cash_entries for all to authenticated using (true) with check (true);
