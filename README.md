# SICV — Prototype carte + saisie terrain (Région du Gbêkê)

Prototype web du **Système d'Information des Cultures Vivrières** (BNETD, Phase 1) pour
la région du Gbêkê : riz, manioc, igname.

**Site en ligne :** https://GITHUB_USERNAME.github.io/sicv-gbeke/

| Page | Rôle |
|---|---|
| [`index.html`](index.html) | Page d'accueil (liens vers les deux outils). |
| [`carte.html`](carte.html) | Carte interactive de restitution. Mode *Performance* (rendement moyen par département, code couleur vert/rouge) et mode *Parcelles* (contours réels collectés). |
| [`formulaire.html`](formulaire.html) | Application de saisie terrain : GPS, tracé de parcelle (Leaflet.Draw), formulaire, enregistrement hors-ligne (`localStorage`) puis synchronisation. |

## Architecture

- **Front** : HTML / CSS / JavaScript natif + [Leaflet.js](https://leafletjs.com/) (aucun build, aucun framework).
- **Back** : [Supabase](https://supabase.com/) (PostgreSQL + PostGIS). Les pages appellent
  directement l'API automatique de Supabase avec la **clé publique `anon`** :
  - lecture de la vue `parcelles_publique` (sans nom ni téléphone du producteur) et de
    la vue d'agrégats `parcelles_totaux_departement` ;
  - écriture via la fonction RPC `enregistrer_parcelle(feature jsonb)` (upsert).
- La table `parcelles` (qui contient le nom et le téléphone du producteur) n'est **pas**
  accessible via la clé publique (Row Level Security activé, aucune policy). Ces champs
  se consultent uniquement depuis le tableau de bord Supabase.
- Le dossier [`db/`](db/) contient les scripts SQL de référence
  (`schema_parcelles.sql` puis `supabase_rls_policies.sql`). Ils ne contiennent aucun
  identifiant.

> La clé `anon` visible dans le code est **publique par conception** : elle n'ouvre que
> les accès ci-dessus. La chaîne de connexion à la base (mot de passe Postgres) n'est
> jamais dans ce dépôt — voir `.gitignore`.

## Déploiement (GitHub Pages)

Ce dépôt est publié tel quel par GitHub Pages depuis la branche `main`, dossier racine.
Aucune étape de build. Le fichier `.nojekyll` désactive le traitement Jekyll.

## Utilisation mobile

Les deux pages sont responsives. La géolocalisation du formulaire exige un contexte
`https://` (fourni par GitHub Pages) et l'autorisation de localisation. Après un premier
chargement, la saisie fonctionne hors-ligne ; seules les tuiles de fond de carte
nécessitent le réseau.

---
Prototype interne BNETD — Phase 1. Données de démonstration.
