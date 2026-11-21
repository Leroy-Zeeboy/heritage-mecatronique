-- =====================================================================
-- Héritage Mécatronique · Parrainage ESTLC · schéma Supabase
-- À coller dans Supabase > SQL Editor > New query, puis « Run ».
-- Peut être relancé sans risque (idempotent).
-- =====================================================================
create extension if not exists pgcrypto;
create extension if not exists unaccent;

-- Organisateurs autorisés (comptes Supabase Auth)
create table if not exists public.organizers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Une cérémonie par année
create table if not exists public.ceremonies (
  id uuid primary key default gen_random_uuid(),
  year int not null unique,
  name text not null default 'Cérémonie de parrainage · Génie Mécatronique · ESTLC',
  access_code_hash text,
  locked boolean not null default false,
  published_at timestamptz,
  published_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- Listes d'étudiants partagées entre organisateurs (données de travail)
create table if not exists public.student_lists (
  ceremony_id uuid not null references public.ceremonies(id) on delete cascade,
  filiere text not null check (filiere in ('TCTL','AMA')),
  role text not null check (role in ('p','f')),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  primary key (ceremony_id, filiere, role)
);

-- Résultat officiel du tirage : une ligne par filleul
create table if not exists public.pairings (
  id bigserial primary key,
  ceremony_id uuid not null references public.ceremonies(id) on delete cascade,
  lot int not null,
  position int not null,
  filiere text not null check (filiere in ('TCTL','AMA')),
  parrain text not null,
  filleul text not null
);
create index if not exists pairings_ceremony_idx on public.pairings(ceremony_id);

-- Tentatives de code (limite les essais au hasard)
create table if not exists public.code_attempts (
  id bigserial primary key,
  ceremony_id uuid not null references public.ceremonies(id) on delete cascade,
  ok boolean not null,
  at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Règles d'accès (RLS)
-- ---------------------------------------------------------------------
create or replace function public.is_organizer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.organizers where user_id = auth.uid());
$$;

alter table public.organizers    enable row level security;
alter table public.ceremonies    enable row level security;
alter table public.student_lists enable row level security;
alter table public.pairings      enable row level security;
alter table public.code_attempts enable row level security;

drop policy if exists org_read_self on public.organizers;
create policy org_read_self on public.organizers for select to authenticated using (user_id = auth.uid());

drop policy if exists cer_read on public.ceremonies;
create policy cer_read on public.ceremonies for select to authenticated using (public.is_organizer());

drop policy if exists lists_all on public.student_lists;
create policy lists_all on public.student_lists for all to authenticated
  using (public.is_organizer()) with check (public.is_organizer());

drop policy if exists pair_read on public.pairings;
create policy pair_read on public.pairings for select to authenticated using (public.is_organizer());
-- Aucune écriture directe sur ceremonies / pairings : tout passe par les fonctions ci-dessous.

revoke all on public.ceremonies, public.pairings, public.code_attempts from anon, authenticated;
grant select on public.ceremonies, public.pairings to authenticated;
grant select, insert, update, delete on public.student_lists to authenticated;
grant select on public.organizers to authenticated;
revoke all on public.student_lists, public.organizers from anon;

-- ---------------------------------------------------------------------
-- Fonctions (RPC)
-- ---------------------------------------------------------------------
-- Cérémonie de l'année (créée au besoin) — organisateurs seulement
create or replace function public.ensure_ceremony(p_year int)
returns public.ceremonies language plpgsql security definer set search_path = public as $$
declare c public.ceremonies;
begin
  if not public.is_organizer() then raise exception 'Réservé aux organisateurs' using errcode = '42501'; end if;
  insert into public.ceremonies(year) values (p_year) on conflict (year) do nothing;
  select * into c from public.ceremonies where year = p_year;
  return c;
end $$;

-- Publie le tirage officiel et le verrouille
-- p_rows : [{"lot":1,"position":1,"filiere":"TCTL","parrain":"…","filleul":"…"}, …]
create or replace function public.publish_draw(p_ceremony uuid, p_code text, p_rows jsonb)
returns public.ceremonies language plpgsql security definer set search_path = public, extensions as $$
declare c public.ceremonies; n int;
begin
  if not public.is_organizer() then raise exception 'Réservé aux organisateurs' using errcode = '42501'; end if;
  select * into c from public.ceremonies where id = p_ceremony for update;
  if not found then raise exception 'Cérémonie introuvable'; end if;
  if c.locked then raise exception 'Le tirage officiel est verrouillé. Déverrouillez-le avec le code avant de le remplacer.' using errcode = 'P0001'; end if;
  if length(coalesce(trim(p_code),'')) < 6 then raise exception 'Le code doit contenir au moins 6 caractères.'; end if;
  n := jsonb_array_length(p_rows);
  if n = 0 then raise exception 'Le tirage est vide.'; end if;
  delete from public.pairings where ceremony_id = p_ceremony;
  insert into public.pairings(ceremony_id, lot, position, filiere, parrain, filleul)
  select p_ceremony, (r->>'lot')::int, (r->>'position')::int, r->>'filiere', r->>'parrain', r->>'filleul'
  from jsonb_array_elements(p_rows) r;
  update public.ceremonies
     set access_code_hash = crypt(trim(p_code), gen_salt('bf')), locked = true,
         published_at = now(), published_by = auth.uid()
   where id = p_ceremony returning * into c;
  return c;
end $$;

-- Déverrouille avec le code (pour refaire le tirage)
create or replace function public.unlock_draw(p_ceremony uuid, p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  if not public.is_organizer() then raise exception 'Réservé aux organisateurs' using errcode = '42501'; end if;
  select access_code_hash into h from public.ceremonies where id = p_ceremony;
  if h is null or crypt(trim(p_code), h) <> h then return false; end if;
  update public.ceremonies set locked = false where id = p_ceremony;
  return true;
end $$;

-- Informations publiques de la cérémonie publiée (sans aucun nom)
create or replace function public.public_ceremony()
returns table(year int, name text, published_at timestamptz, filleuls int)
language sql stable security definer set search_path = public as $$
  select c.year, c.name, c.published_at, (select count(*)::int from public.pairings p where p.ceremony_id = c.id)
  from public.ceremonies c where c.locked order by c.year desc limit 1;
$$;

-- Recherche publique : renvoie seulement les familles qui contiennent le nom cherché
create or replace function public.find_family(p_code text, p_query text)
returns table(role text, nom text, filiere text, lot int, parrain text, filleuls text[])
language plpgsql security definer set search_path = public, extensions as $$
declare c public.ceremonies; fails int; toks text[]; q text;
begin
  select * into c from public.ceremonies where locked order by year desc limit 1;
  if not found then raise exception 'Les résultats ne sont pas encore publiés.' using errcode = 'P0002'; end if;
  select count(*) into fails from public.code_attempts
   where ceremony_id = c.id and not ok and at > now() - interval '10 minutes';
  if fails >= 30 then raise exception 'Trop d''essais. Réessayez dans quelques minutes.' using errcode = 'P0003'; end if;
  if crypt(trim(coalesce(p_code,'')), c.access_code_hash) <> c.access_code_hash then
    -- on n'utilise pas raise ici, sinon l'essai raté serait annulé et la limite ne marcherait pas
    insert into public.code_attempts(ceremony_id, ok) values (c.id, false);
    return query select '__code_incorrect__'::text, null::text, null::text, null::int, null::text, null::text[];
    return;
  end if;
  q := lower(unaccent(trim(coalesce(p_query,''))));
  toks := array(select t from unnest(regexp_split_to_array(q, '\s+')) t where length(t) >= 2);
  if coalesce(array_length(toks,1),0) = 0 or length(q) < 3 then return; end if;
  return query
  with fam as (
    select p.parrain, p.filiere, min(p.lot) as lot, array_agg(p.filleul order by p.position, p.id) as filleuls
    from public.pairings p where p.ceremony_id = c.id group by p.parrain, p.filiere
  ), people as (
    select 'Parrain'::text as role, f.parrain as nom, f.* from fam f
    union all
    select 'Filleul', x.nom, f.* from fam f, unnest(f.filleuls) as x(nom)
  )
  select pe.role, pe.nom, pe.filiere, pe.lot, pe.parrain, pe.filleuls from people pe
  where (select bool_and(lower(unaccent(pe.nom)) like '%' || t || '%') from unnest(toks) t)
  order by pe.nom limit 20;
end $$;

revoke all on function public.ensure_ceremony(int), public.publish_draw(uuid,text,jsonb), public.unlock_draw(uuid,text) from public, anon;
grant execute on function public.ensure_ceremony(int), public.publish_draw(uuid,text,jsonb), public.unlock_draw(uuid,text) to authenticated;
grant execute on function public.public_ceremony(), public.find_family(text,text) to anon, authenticated;
grant execute on function public.is_organizer() to authenticated;
