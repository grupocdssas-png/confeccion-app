-- Equivalente a los privilegios por defecto que Supabase da a anon/authenticated (RLS decide).
grant select, insert, update, delete on all tables in schema public to anon, authenticated, service_role;
grant usage on all sequences in schema public to anon, authenticated, service_role;
