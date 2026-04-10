-- ============================================================
-- SCHÉMA SUPABASE — Pronostics Coupe du Monde 2026
-- À exécuter dans l'éditeur SQL de Supabase
-- ============================================================

-- Extension pour générer des UUID
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ------------------------------------------------------------
-- PARTICIPANTS
-- ------------------------------------------------------------
CREATE TABLE participants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pseudo      TEXT NOT NULL UNIQUE,
  pin_hash    TEXT NOT NULL,          -- bcrypt hash du PIN à 4 chiffres
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ------------------------------------------------------------
-- PRONOSTICS — PHASE DE GROUPES (matchs)
-- Un enregistrement par participant × match
-- ------------------------------------------------------------
CREATE TABLE pronostics_groupes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id  UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  match_id        TEXT NOT NULL,      -- ex : "A_1", "B_3", ... (cf. config.json)
  resultat        CHAR(1) NOT NULL CHECK (resultat IN ('H','N','A')),
                                      -- H = domicile, N = nul, A = extérieur
  score_dom       SMALLINT CHECK (score_dom >= 0),
  score_ext       SMALLINT CHECK (score_ext >= 0),
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (participant_id, match_id)
);


-- ------------------------------------------------------------
-- PRONOSTICS — QUALIFIÉS DE GROUPES
-- Un enregistrement par participant × groupe
-- ------------------------------------------------------------
CREATE TABLE pronostics_qualifies (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id  UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  groupe_id       CHAR(1) NOT NULL CHECK (groupe_id IN ('A','B','C','D','E','F','G','H','I','J','K','L')),
  equipe_1er      TEXT NOT NULL,      -- code équipe (ex : "FRA")
  equipe_2eme     TEXT NOT NULL,
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (participant_id, groupe_id)
);


-- ------------------------------------------------------------
-- PRONOSTICS — MEILLEURS 3ES DE GROUPE
-- 8 groupes parmi 12 dont le 3e se qualifie
-- Stocké comme tableau de 8 lettres de groupe
-- ------------------------------------------------------------
CREATE TABLE pronostics_meilleurs_tiers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id  UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  groupes         CHAR(1)[] NOT NULL, -- tableau de 8 lettres, ex : ['A','C','D','E','G','H','J','K']
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (participant_id)
);


-- ------------------------------------------------------------
-- PRONOSTICS — BRACKET ÉLIMINATOIRE (pronostiqué avant le tournoi)
-- Un enregistrement par participant × slot du bracket
-- Le slot identifie la position dans l'arbre : tour + numéro
-- ex : "R32_1", "R16_3", "QF_2", "SF_1", "P3", "F"
-- ------------------------------------------------------------
CREATE TABLE pronostics_bracket (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id  UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  slot_id         TEXT NOT NULL,      -- ex : "R32_1", "QF_2", "F"
  equipe          TEXT NOT NULL,      -- code équipe pronostiquée vainqueur de ce match
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (participant_id, slot_id)
);


-- ------------------------------------------------------------
-- PRONOSTICS — QUESTIONS BONUS
-- Un enregistrement par participant × question
-- ------------------------------------------------------------
CREATE TABLE pronostics_bonus (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id  UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  question_id     TEXT NOT NULL,      -- ex : "b1", "b2" (cf. config.json)
  reponse_equipe  TEXT,               -- si type = "equipe"
  reponse_entier  INTEGER,            -- si type = "entier"
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (participant_id, question_id)
);


-- ------------------------------------------------------------
-- PRONOSTICS — MATCHS ÉLIMINATOIRES RÉELS (en cours de tournoi)
-- Pronostics indépendants, verrouillés journée par journée
-- ------------------------------------------------------------
CREATE TABLE pronostics_elim (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id  UUID NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  match_id        TEXT NOT NULL,      -- ex : "R32_1", "QF_2" (même IDs que bracket)
  resultat        CHAR(1) NOT NULL CHECK (resultat IN ('H','N','A')),
  score_dom       SMALLINT CHECK (score_dom >= 0),
  score_ext       SMALLINT CHECK (score_ext >= 0),
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (participant_id, match_id)
);


-- ------------------------------------------------------------
-- MATCHS RÉELS (saisie admin)
-- Contient les scores officiels et l'état de verrouillage
-- ------------------------------------------------------------
CREATE TABLE matchs_reels (
  match_id        TEXT PRIMARY KEY,   -- ex : "A_1", "R32_3", "F"
  equipe_dom      TEXT,               -- code équipe domicile (rempli par admin)
  equipe_ext      TEXT,               -- code équipe extérieur
  score_dom       SMALLINT,           -- NULL tant que non joué
  score_ext       SMALLINT,
  verrouille      BOOLEAN NOT NULL DEFAULT FALSE,
  joue            BOOLEAN NOT NULL DEFAULT FALSE,
  date_match      TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ------------------------------------------------------------
-- SCORES CALCULÉS (cache, recalculé à chaque mise à jour admin)
-- ------------------------------------------------------------
CREATE TABLE scores_calcules (
  participant_id      UUID PRIMARY KEY REFERENCES participants(id) ON DELETE CASCADE,
  pts_matchs_groupes  INTEGER NOT NULL DEFAULT 0,
  pts_qualifies       INTEGER NOT NULL DEFAULT 0,
  pts_bracket         INTEGER NOT NULL DEFAULT 0,
  pts_matchs_elim     INTEGER NOT NULL DEFAULT 0,
  pts_bonus           INTEGER NOT NULL DEFAULT 0,
  total               INTEGER NOT NULL DEFAULT 0,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

ALTER TABLE participants          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pronostics_groupes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pronostics_qualifies  ENABLE ROW LEVEL SECURITY;
ALTER TABLE pronostics_meilleurs_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE pronostics_bracket    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pronostics_bonus      ENABLE ROW LEVEL SECURITY;
ALTER TABLE pronostics_elim       ENABLE ROW LEVEL SECURITY;
ALTER TABLE matchs_reels          ENABLE ROW LEVEL SECURITY;
ALTER TABLE scores_calcules       ENABLE ROW LEVEL SECURITY;

-- Lecture publique du classement (scores)
CREATE POLICY "classement_public"
  ON scores_calcules FOR SELECT
  USING (TRUE);

-- Lecture publique des pseudos (pour le classement)
CREATE POLICY "pseudos_publics"
  ON participants FOR SELECT
  USING (TRUE);

-- Lecture publique des matchs réels (scores officiels)
CREATE POLICY "matchs_publics"
  ON matchs_reels FOR SELECT
  USING (TRUE);

-- Lecture publique des pronostics APRÈS verrouillage de la journée
-- (géré côté applicatif — les pronostics sont lus via une fonction RPC)
CREATE POLICY "pronostics_groupes_public"
  ON pronostics_groupes FOR SELECT
  USING (TRUE);

CREATE POLICY "pronostics_qualifies_public"
  ON pronostics_qualifies FOR SELECT
  USING (TRUE);

CREATE POLICY "pronostics_bracket_public"
  ON pronostics_bracket FOR SELECT
  USING (TRUE);

CREATE POLICY "pronostics_elim_public"
  ON pronostics_elim FOR SELECT
  USING (TRUE);

-- Insert/Update via anon key (authentification gérée côté app avec PIN)
CREATE POLICY "insert_pronostics_groupes"
  ON pronostics_groupes FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "insert_pronostics_qualifies"
  ON pronostics_qualifies FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "insert_pronostics_tiers"
  ON pronostics_meilleurs_tiers FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "insert_pronostics_bracket"
  ON pronostics_bracket FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "insert_pronostics_bonus"
  ON pronostics_bonus FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "insert_pronostics_elim"
  ON pronostics_elim FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "insert_participant"
  ON participants FOR INSERT
  WITH CHECK (TRUE);

-- Admin uniquement pour matchs_reels et scores_calcules (via service_role key)
-- Ces tables ne sont écrites que depuis ton interface admin


-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX idx_prog_participant  ON pronostics_groupes   (participant_id);
CREATE INDEX idx_prog_match        ON pronostics_groupes   (match_id);
CREATE INDEX idx_proq_participant  ON pronostics_qualifies (participant_id);
CREATE INDEX idx_prob_participant  ON pronostics_bracket   (participant_id);
CREATE INDEX idx_proe_participant  ON pronostics_elim      (participant_id);
CREATE INDEX idx_proe_match        ON pronostics_elim      (match_id);
CREATE INDEX idx_scores_total      ON scores_calcules      (total DESC);
