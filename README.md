# Héritage Mécatronique : mise en place du backend Supabase

Le site se compose de 3 fichiers à héberger (GitHub Pages ou Netlify) : `index.html`, `config.js`, et le dossier `supabase/`, qui ne sert qu'une fois pour créer la base.

## 1. Créer le projet Supabase
1. Créez un compte sur https://supabase.com, puis un projet (région la plus proche : Europe West, par exemple).
2. Ouvrez **SQL Editor > New query**, collez tout le contenu de `supabase/schema.sql`, puis cliquez sur **Run**.

## 2. Créer les comptes organisateurs
1. **Authentication > Users > Add user** : saisissez l'e-mail et le mot de passe de chaque organisateur (cochez « Auto confirm »).
2. Dans **SQL Editor**, autorisez-les comme organisateurs :
   ```sql
   insert into public.organizers (user_id)
   select id from auth.users where email in ('organisateur1@exemple.com', 'organisateur2@exemple.com')
   on conflict do nothing;
   ```
3. Dans **Authentication > Providers > Email**, vous pouvez désactiver « Allow new users to sign up », pour que personne d'autre ne puisse créer de compte.

## 3. Renseigner config.js
Dans **Project Settings > API**, copiez « Project URL » et la clé « anon public » dans `config.js`. Ne mettez jamais la clé `service_role` dans ce fichier.

## Ce que fait le serveur
- **Organisateurs connectés** : les listes importées sont partagées entre tous les organisateurs. Ils lancent le tirage, puis le publient avec un code d'accès d'au moins 6 caractères.
- **Tirage publié = verrouillé** : la base refuse de le remplacer tant qu'il n'a pas été déverrouillé avec le code.
- **Absents** : sur l'onglet Résultats, ils tapent le code puis leur nom. Le serveur ne renvoie que les familles qui correspondent à la recherche, jamais la liste complète. Après 30 codes faux en 10 minutes, la recherche est bloquée quelques minutes.
- **Version hors ligne** (`parrainage-hors-ligne.html`) : elle reste utilisable le jour J sans internet. Exportez ensuite le tirage en Excel et rechargez-le sur le site avec « Charger un tirage déjà fait » avant de le publier.
