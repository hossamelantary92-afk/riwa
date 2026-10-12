-- Run once in Supabase SQL Editor to enable book notes.
alter table public.books
  add column if not exists notes text not null default ''
  check (char_length(notes) <= 50000);
