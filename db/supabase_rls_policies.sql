-- ============================================================================
-- Sécurité (Row Level Security) + API publique Supabase — Parcelles Gbêkê
-- À exécuter APRÈS schema_parcelles.sql
--
-- Modèle d'accès :
--   • rôle "anon" (clé publique, utilisée par la carte et le formulaire) :
--       - LECTURE : vue parcelles_publique (sans producteur ni téléphone)
--                   + vue parcelles_totaux_departement (agrégats, sans données perso)
--       - ÉCRITURE : uniquement via la fonction RPC enregistrer_parcelle()
--   • table "parcelles" : jamais lisible via l'API publique (RLS activé, aucune
--     policy). Les colonnes producteur / telephone_producteur se consultent
--     uniquement depuis le tableau de bord Supabase (SQL Editor).
--   • vue "parcelles_geojson" : contient producteur + téléphone => NON exposée
--     à anon (réservée au SQL Editor / rôle de service).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. RLS sur les tables de base : activé, AUCUNE policy pour anon.
--    Résultat : GET /rest/v1/parcelles et /rest/v1/parcelles_historique
--    ne renvoient jamais aucune ligne via la clé publique.
-- ----------------------------------------------------------------------------
ALTER TABLE parcelles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE parcelles_historique ENABLE ROW LEVEL SECURITY;

-- Défense en profondeur : retire aussi les privilèges de table éventuellement
-- accordés par défaut aux rôles publics.
REVOKE ALL ON parcelles            FROM anon, authenticated;
REVOKE ALL ON parcelles_historique FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. Vue publique : identique à parcelles_geojson MAIS sans les champs
--    "producteur" et "telephone". C'est cette vue que la carte interroge.
--    security_invoker = false (défaut) => la vue lit la table sous les droits
--    de son propriétaire (postgres, BYPASSRLS) : les lignes restent visibles
--    à travers la vue même si le RLS bloque l'accès direct à la table.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS parcelles_publique;
CREATE VIEW parcelles_publique
  WITH (security_invoker = false)
AS
SELECT
  id,
  ST_AsGeoJSON(geom)::json AS geometry,
  json_build_object(
    'id', id,
    'culture', culture,
    'departement', departement,
    'localite', localite,
    'surface_ha', surface_ha,
    'stade_culture', stade_culture,
    'rendement_estime_t_ha', rendement_estime_t_ha,
    'production_estimee_t', production_estimee_t,
    'date_plantation', date_plantation,
    'date_collecte', date_collecte,
    'agent_enqueteur', agent_enqueteur,
    'notes', notes,
    'photo_url', photo_url,
    'source', source,
    'synced', true,
    'created_at', created_at,
    'updated_at', updated_at
  ) AS properties
FROM parcelles;

COMMENT ON VIEW parcelles_publique IS
  'Vue publique des parcelles (GeoJSON) SANS producteur ni téléphone — interrogée par la carte via la clé anon.';

-- ----------------------------------------------------------------------------
-- 3. Exposition en lecture publique.
-- ----------------------------------------------------------------------------
GRANT SELECT ON parcelles_publique           TO anon, authenticated;
GRANT SELECT ON parcelles_totaux_departement TO anon, authenticated;

-- Lecture seule : Supabase accorde par défaut tous les privilèges aux rôles
-- publics sur les objets du schéma public ; on retire ici tout ce qui n'est
-- pas du SELECT sur ces deux vues.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON parcelles_publique, parcelles_totaux_departement
  FROM anon, authenticated;

-- parcelles_geojson contient producteur + téléphone : on la garde hors de
-- portée de la clé publique.
REVOKE ALL ON parcelles_geojson FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Fonction d'upsert exposée en écriture via RPC pour le rôle anon.
--    Reproduit la logique de l'ancien api/parcelles.php (POST d'une Feature
--    GeoJSON => insertion, ou mise à jour si l'id existe déjà).
--    SECURITY DEFINER : s'exécute avec les droits du propriétaire (postgres),
--    donc peut écrire dans "parcelles" malgré le RLS. La fonction valide les
--    champs requis, exactement comme le faisait le script PHP.
--    Le nom et le téléphone du producteur SONT enregistrés (ils sont
--    seulement exclus de la lecture publique, pas de l'écriture).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enregistrer_parcelle(feature jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  p       jsonb;
  g       jsonb;
  v_id    uuid;
  v_photo text;
BEGIN
  IF feature IS NULL
     OR feature->>'type' IS DISTINCT FROM 'Feature'
     OR feature->'geometry' IS NULL
     OR feature->'properties' IS NULL THEN
    RAISE EXCEPTION 'Feature GeoJSON invalide.' USING ERRCODE = '22023';
  END IF;

  p := feature->'properties';
  g := feature->'geometry';

  -- Champs requis (mêmes règles que l'ancien api/parcelles.php)
  IF COALESCE(p->>'id','')              = '' THEN RAISE EXCEPTION 'Champ requis manquant : id'              USING ERRCODE='22023'; END IF;
  IF COALESCE(p->>'culture','')         = '' THEN RAISE EXCEPTION 'Champ requis manquant : culture'         USING ERRCODE='22023'; END IF;
  IF COALESCE(p->>'departement','')     = '' THEN RAISE EXCEPTION 'Champ requis manquant : departement'     USING ERRCODE='22023'; END IF;
  IF COALESCE(p->>'localite','')        = '' THEN RAISE EXCEPTION 'Champ requis manquant : localite'        USING ERRCODE='22023'; END IF;
  IF COALESCE(p->>'surface_ha','')      = '' THEN RAISE EXCEPTION 'Champ requis manquant : surface_ha'      USING ERRCODE='22023'; END IF;
  IF COALESCE(p->>'agent_enqueteur','') = '' THEN RAISE EXCEPTION 'Champ requis manquant : agent_enqueteur' USING ERRCODE='22023'; END IF;

  v_id := (p->>'id')::uuid;

  -- L'app terrain envoie la photo en base64 ; on ne conserve ici qu'une URL http(s)
  -- (le re-téléversement vers un bucket est un TODO côté serveur, comme dans le PHP).
  v_photo := CASE
    WHEN p->>'photo'     LIKE 'http%' THEN p->>'photo'
    WHEN p->>'photo_url' LIKE 'http%' THEN p->>'photo_url'
    ELSE NULL
  END;

  INSERT INTO parcelles (
    id, geom, culture, departement, localite, producteur, telephone_producteur,
    surface_ha, stade_culture, rendement_estime_t_ha, production_estimee_t,
    date_plantation, date_collecte, agent_enqueteur, notes, photo_url, source
  ) VALUES (
    v_id,
    ST_SetSRID(ST_GeomFromGeoJSON(g::text), 4326),
    p->>'culture',
    p->>'departement',
    p->>'localite',
    NULLIF(p->>'producteur', ''),
    NULLIF(p->>'telephone', ''),
    (p->>'surface_ha')::numeric,
    NULLIF(p->>'stade_culture', ''),
    NULLIF(p->>'rendement_estime_t_ha', '')::numeric,
    NULLIF(p->>'production_estimee_t', '')::numeric,
    NULLIF(p->>'date_plantation', '')::date,
    COALESCE(NULLIF(p->>'date_collecte', '')::date, CURRENT_DATE),
    p->>'agent_enqueteur',
    NULLIF(p->>'notes', ''),
    v_photo,
    'terrain'
  )
  ON CONFLICT (id) DO UPDATE SET
    geom                  = EXCLUDED.geom,
    culture               = EXCLUDED.culture,
    departement           = EXCLUDED.departement,
    localite              = EXCLUDED.localite,
    producteur            = EXCLUDED.producteur,
    telephone_producteur  = EXCLUDED.telephone_producteur,
    surface_ha            = EXCLUDED.surface_ha,
    stade_culture         = EXCLUDED.stade_culture,
    rendement_estime_t_ha = EXCLUDED.rendement_estime_t_ha,
    production_estimee_t  = EXCLUDED.production_estimee_t,
    date_plantation       = EXCLUDED.date_plantation,
    date_collecte         = EXCLUDED.date_collecte,
    agent_enqueteur       = EXCLUDED.agent_enqueteur,
    notes                 = EXCLUDED.notes,
    photo_url             = COALESCE(EXCLUDED.photo_url, parcelles.photo_url);

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

COMMENT ON FUNCTION enregistrer_parcelle(jsonb) IS
  'Upsert d''une parcelle terrain (Feature GeoJSON) — remplace POST api/parcelles.php. Exposée en RPC pour le rôle anon.';

-- Seul anon/authenticated peut l'appeler (pas "public" au sens large).
REVOKE ALL     ON FUNCTION enregistrer_parcelle(jsonb) FROM public;
GRANT  EXECUTE ON FUNCTION enregistrer_parcelle(jsonb) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. Rafraîchit le cache de schéma de PostgREST (pour que la RPC et les vues
--    soient immédiatement visibles sur l'API REST).
-- ----------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
