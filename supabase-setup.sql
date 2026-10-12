-- Run once in Supabase > SQL Editor. No passwords or secret keys required.
begin;
create table if not exists public.books (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  author text not null default '' check (char_length(author) <= 200),
  status text not null default 'toread' check (status in ('reading','read','toread')),
  rating integer not null default 0 check (rating between 0 and 5),
  summary text not null default '' check (char_length(summary) <= 20000),
  notes text not null default '' check (char_length(notes) <= 50000),
  cover text not null default '' check (octet_length(cover) <= 260000),
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists books_owner_idx on public.books(user_id);
alter table public.books add column if not exists notes text not null default '' check (char_length(notes) <= 50000);
alter table public.books enable row level security;
revoke all on public.books from anon;
grant select, insert, update, delete on public.books to authenticated;
drop policy if exists own_books_select on public.books;
create policy own_books_select on public.books for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists own_books_insert on public.books;
create policy own_books_insert on public.books for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists own_books_update on public.books;
create policy own_books_update on public.books for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists own_books_delete on public.books;
create policy own_books_delete on public.books for delete to authenticated using ((select auth.uid()) = user_id);
create or replace function public.touch_book_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = clock_timestamp();
  return new;
end;
$$;
drop trigger if exists books_updated_at on public.books;
create trigger books_updated_at before update on public.books for each row execute function public.touch_book_updated_at();
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='books') then
    alter publication supabase_realtime add table public.books;
  end if;
end $$;
commit;
