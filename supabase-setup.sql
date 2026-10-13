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

-- Run in Supabase SQL Editor once. Existing books and notes are preserved.
begin;
alter table public.books add column if not exists total_pages integer not null default 0 check (total_pages between 0 and 100000);
alter table public.books add column if not exists current_page integer not null default 0 check (current_page >= 0);
create table if not exists public.reading_sessions (
 id uuid primary key default gen_random_uuid(),
 book_id uuid not null references public.books(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 start_page integer not null check (start_page >= 0),
 end_page integer not null check (end_page >= start_page),
 duration_seconds integer check (duration_seconds between 0 and 604800),
 read_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 deleted boolean not null default false
);
create index if not exists reading_sessions_owner_book on public.reading_sessions(user_id, book_id);
alter table public.reading_sessions enable row level security;
revoke all on public.reading_sessions from anon, authenticated;
grant select on public.reading_sessions to authenticated;
drop policy if exists own_reading_sessions on public.reading_sessions;
create policy own_reading_sessions on public.reading_sessions for select to authenticated
 using ((select auth.uid()) = user_id and exists (select 1 from public.books b where b.id=book_id and b.user_id=(select auth.uid()) and not b.deleted));

-- All session writes lock the parent book, validate ownership, and recalculate progress atomically.
create or replace function public.save_reading(
 p_book uuid, p_action text, p_total integer default null,
 p_id uuid default null, p_start integer default null, p_end integer default null,
 p_seconds integer default null, p_date timestamptz default null,
 p_version timestamptz default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.books; s public.reading_sessions; reached integer; session_id uuid;
begin
 if auth.uid() is null then raise exception 'LOGIN_REQUIRED'; end if;
 select * into b from public.books where id=p_book and user_id=auth.uid() and not deleted for update;
 if not found then raise exception 'BOOK_NOT_FOUND'; end if;
 if p_action='total' then
   if p_total is null or p_total<1 or p_total>100000 then raise exception 'INVALID_TOTAL'; end if;
   if p_version is distinct from b.updated_at then raise exception 'READING_CONFLICT'; end if;
   select coalesce(max(end_page),0) into reached from public.reading_sessions where book_id=b.id and not deleted;
   if p_total<reached then raise exception 'TOTAL_BELOW_PROGRESS'; end if;
   update public.books set total_pages=p_total where id=b.id;
   b.total_pages:=p_total;
 elsif p_action in ('save','delete') then
   if b.total_pages<1 then raise exception 'TOTAL_REQUIRED'; end if;
   select * into s from public.reading_sessions where id=p_id and book_id=b.id and user_id=auth.uid() and not deleted;
   if p_action='delete' then
     if s.id is null then raise exception 'SESSION_NOT_FOUND'; end if;
     if p_version is distinct from s.updated_at then raise exception 'READING_CONFLICT'; end if;
     update public.reading_sessions set deleted=true,updated_at=clock_timestamp() where id=s.id;
   else
     if p_start is null or p_end is null or p_start<0 or p_end<p_start or p_end>b.total_pages then raise exception 'INVALID_PAGES'; end if;
     if p_seconds is not null and (p_seconds<0 or p_seconds>604800) then raise exception 'INVALID_DURATION'; end if;
     if p_date is null or p_date>now()+interval '5 minutes' then raise exception 'INVALID_DATE'; end if;
     if s.id is not null then
       if p_version is null and s.start_page=p_start and s.end_page=p_end and s.duration_seconds is not distinct from p_seconds and s.read_at=p_date then
         return jsonb_build_object('id',s.id,'replayed',true);
       end if;
       if p_version is distinct from s.updated_at then raise exception 'READING_CONFLICT'; end if;
       update public.reading_sessions set start_page=p_start,end_page=p_end,duration_seconds=p_seconds,read_at=p_date,updated_at=clock_timestamp() where id=s.id;
       session_id:=s.id;
     else
       if p_version is not null then raise exception 'SESSION_NOT_FOUND'; end if;
       session_id:=coalesce(p_id,gen_random_uuid());
       insert into public.reading_sessions(id,book_id,user_id,start_page,end_page,duration_seconds,read_at)
       values(session_id,b.id,auth.uid(),p_start,p_end,p_seconds,p_date);
     end if;
   end if;
 else raise exception 'INVALID_ACTION'; end if;
 select coalesce(max(end_page),0) into reached from public.reading_sessions where book_id=b.id and not deleted;
 update public.books set current_page=reached,status=case
   when reached>=b.total_pages and b.total_pages>0 then 'read'
   when reached>0 then 'reading'
   when b.current_page>0 then 'toread' else status end where id=b.id;
 return jsonb_build_object('id',session_id,'current_page',reached,'total_pages',b.total_pages);
end $$;
revoke all on function public.save_reading(uuid,text,integer,uuid,integer,integer,integer,timestamptz,timestamptz) from public, anon;
grant execute on function public.save_reading(uuid,text,integer,uuid,integer,integer,integer,timestamptz,timestamptz) to authenticated;
do $$ begin
 if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reading_sessions') then
  alter publication supabase_realtime add table public.reading_sessions;
 end if;
end $$;
commit;
