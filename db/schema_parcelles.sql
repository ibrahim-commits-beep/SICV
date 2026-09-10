-- ============================================================================
-- Base de données des parcelles — Région du Gbêkê
-- PostgreSQL + PostGIS
--
-- Installation :
--   createdb gbeke_parcelles
--   psql gbeke_parcelles -f schema_parcelles.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- pour gen_random_uuid()

-- ----------------------------------------------------------------------------
-- Table principale : une ligne = une parcelle numérisée sur le terrain
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parcelles (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Géométrie : polygone numérisé au GPS/terrain, en WGS84 (EPSG:4326)
  geom                    GEOMETRY(Polygon, 4326) NOT NULL,

  -- Culture et localisation administrative
  culture                 VARCHAR(30) NOT NULL
                          CHECK (culture IN ('riz','manioc','igname','autre')),
  departement             VARCHAR(50) NOT NULL
                          CHECK (departement IN ('Béoumi','Botro','Bouaké','Sakassou')),
  localite                VARCHAR(150) NOT NULL,

  -- Exploitant
  producteur              VARCHAR(150),
  telephone_producteur    VARCHAR(30),

  -- Mesures
  surface_ha              NUMERIC(9,2) NOT NULL CHECK (surface_ha > 0),
  stade_culture           VARCHAR(30)
                          CHECK (stade_culture IN
                            ('preparation','semis','croissance','floraison','recolte','jachere') OR stade_culture IS NULL),
  rendement_estime_t_ha   NUMERIC(6,2) CHECK (rendement_estime_t_ha IS NULL OR rendement_estime_t_ha >= 0),
  production_estimee_t    NUMERIC(10,2) CHECK (production_estimee_t IS NULL OR production_estimee_t >= 0),

  -- Suivi de collecte
  date_plantation         DATE,
  date_collecte           DATE NOT NULL DEFAULT CURRENT_DATE,
  agent_enqueteur         VARCHAR(150) NOT NULL,
  notes                   TEXT,
  photo_url               TEXT,          -- URL vers un stockage objet (S3, etc.) — l'app terrain
                                          -- envoie la photo en base64 ; à re-téléverser côté serveur
                                          -- vers un bucket puis stocker l'URL ici.

  source                  VARCHAR(20) NOT NULL DEFAULT 'terrain'
                          CHECK (source IN ('terrain','simulation','import')),

  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_parcelles_geom         ON parcelles USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_parcelles_culture       ON parcelles (culture);
CREATE INDEX IF NOT EXISTS idx_parcelles_departement   ON parcelles (departement);
CREATE INDEX IF NOT EXISTS idx_parcelles_date_collecte ON parcelles (date_collecte);

-- ----------------------------------------------------------------------------
-- Historique : conserve chaque version précédente lors d'une mise à jour
-- terrain (utile pour l'audit / le suivi de l'évolution d'une parcelle)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parcelles_historique (
  hist_id       BIGSERIAL PRIMARY KEY,
  parcelle_id   UUID NOT NULL,
  donnees       JSONB NOT NULL,     -- snapshot complet (géométrie + attributs) avant modification
  modifie_le    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION parcelles_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION parcelles_archive_before_update() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO parcelles_historique (parcelle_id, donnees)
  VALUES (OLD.id, to_jsonb(OLD));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_parcelles_updated_at ON parcelles;
CREATE TRIGGER trg_parcelles_updated_at
  BEFORE UPDATE ON parcelles
  FOR EACH ROW EXECUTE FUNCTION parcelles_set_updated_at();

DROP TRIGGER IF EXISTS trg_parcelles_archive ON parcelles;
CREATE TRIGGER trg_parcelles_archive
  BEFORE UPDATE ON parcelles
  FOR EACH ROW EXECUTE FUNCTION parcelles_archive_before_update();

-- ----------------------------------------------------------------------------
-- Vue GeoJSON : une ligne par parcelle, prête à être assemblée en
-- FeatureCollection côté API (voir server-sync-example/server.js)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW parcelles_geojson AS
SELECT
  id,
  ST_AsGeoJSON(geom)::json AS geometry,
  json_build_object(
    'id', id,
    'culture', culture,
    'departement', departement,
    'localite', localite,
    'producteur', producteur,
    'telephone', telephone_producteur,
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

-- ----------------------------------------------------------------------------
-- Vue d'agrégation par département / culture — pratique pour retrouver les
-- totaux affichés par le mode "Performance" de la carte interactive
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW parcelles_totaux_departement AS
SELECT
  departement,
  culture,
  COUNT(*)                          AS nb_parcelles,
  SUM(surface_ha)                   AS surface_totale_ha,
  SUM(COALESCE(production_estimee_t, 0)) AS production_totale_t,
  ROUND(AVG(rendement_estime_t_ha)::numeric, 2) AS rendement_moyen_t_ha
FROM parcelles
GROUP BY departement, culture
ORDER BY departement, culture;

-- ----------------------------------------------------------------------------
-- Exemple d'insertion manuelle (pour test)
-- ----------------------------------------------------------------------------
-- INSERT INTO parcelles (geom, culture, departement, localite, producteur,
--   surface_ha, stade_culture, rendement_estime_t_ha, production_estimee_t,
--   date_collecte, agent_enqueteur, notes)
-- VALUES (
--   ST_GeomFromGeoJSON('{"type":"Polygon","coordinates":[[[-5.03,7.69],[-5.02,7.69],[-5.02,7.70],[-5.03,7.70],[-5.03,7.69]]]}'),
--   'riz', 'Bouaké', 'Mamini', 'Kouassi Yao', 2.4, 'croissance', 2.8, 6.72,
--   CURRENT_DATE, 'Agent Test', 'Parcelle de démonstration'
-- );

-- Export rapide en GeoJSON depuis psql :
--   \COPY (SELECT json_build_object('type','FeatureCollection','features',
--     json_agg(json_build_object('type','Feature','geometry',geometry,'properties',properties)))
--     FROM parcelles_geojson) TO 'parcelles_export.geojson'
