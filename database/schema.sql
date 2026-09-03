-- =====================================================================
-- Intelligent Land Record Digitization and Validation System
-- PostgreSQL + PostGIS Database Schema
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 1. USERS & ROLE-BASED ACCESS CONTROL
-- ---------------------------------------------------------------------
CREATE TABLE roles (
    role_id SERIAL PRIMARY KEY,
    role_name VARCHAR(50) UNIQUE NOT NULL,       -- e.g. 'admin', 'tehsildar', 'clerk', 'viewer'
    permissions JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(100) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(150),
    role_id INTEGER REFERENCES roles(role_id),
    district VARCHAR(100),
    tehsil VARCHAR(100),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT now(),
    last_login TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- 2. ADMINISTRATIVE HIERARCHY (State > District > Tehsil > Village)
-- ---------------------------------------------------------------------
CREATE TABLE administrative_units (
    unit_id SERIAL PRIMARY KEY,
    unit_type VARCHAR(20) NOT NULL CHECK (unit_type IN ('state','district','tehsil','village')),
    unit_name VARCHAR(150) NOT NULL,
    parent_unit_id INTEGER REFERENCES administrative_units(unit_id),
    boundary GEOMETRY(MultiPolygon, 4326)          -- GIS boundary polygon
);

-- ---------------------------------------------------------------------
-- 3. DOCUMENT INGESTION
-- ---------------------------------------------------------------------
CREATE TABLE documents (
    document_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    original_filename VARCHAR(500) NOT NULL,
    storage_path TEXT NOT NULL,                    -- S3/blob path to original scan
    processed_path TEXT,                           -- path to OpenCV-cleaned image
    document_type VARCHAR(50),                     -- 'register','map','pdf','photo'
    language_detected VARCHAR(20),
    upload_status VARCHAR(30) DEFAULT 'queued'      -- queued, processing, ocr_done, validated, failed
        CHECK (upload_status IN ('queued','processing','ocr_done','validated','failed')),
    uploaded_by UUID REFERENCES users(user_id),
    village_unit_id INTEGER REFERENCES administrative_units(unit_id),
    page_count INTEGER DEFAULT 1,
    file_hash VARCHAR(128),                        -- SHA-256 for duplicate detection
    uploaded_at TIMESTAMPTZ DEFAULT now(),
    processed_at TIMESTAMPTZ
);

CREATE INDEX idx_documents_status ON documents(upload_status);
CREATE INDEX idx_documents_hash ON documents(file_hash);

-- ---------------------------------------------------------------------
-- 4. LAND RECORDS (core structured entity)
-- ---------------------------------------------------------------------
CREATE TABLE land_records (
    record_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id UUID REFERENCES documents(document_id),
    khasra_number VARCHAR(50),
    khata_number VARCHAR(50),
    survey_number VARCHAR(50),
    landowner_name VARCHAR(255),
    landowner_guardian_name VARCHAR(255),
    village_unit_id INTEGER REFERENCES administrative_units(unit_id),
    tehsil_unit_id INTEGER REFERENCES administrative_units(unit_id),
    district_unit_id INTEGER REFERENCES administrative_units(unit_id),
    plot_area_value NUMERIC(12,4),
    plot_area_unit VARCHAR(20) DEFAULT 'hectare',   -- hectare, acre, bigha
    land_classification VARCHAR(100),               -- agricultural, residential, barren, etc.
    ownership_type VARCHAR(50),                      -- individual, joint, government, disputed
    mutation_status VARCHAR(50),
    registration_number VARCHAR(100),
    registration_date DATE,
    geo_boundary GEOMETRY(Polygon, 4326),            -- cadastral polygon (from GIS overlay)
    overall_confidence NUMERIC(5,2),                 -- 0-100, aggregate OCR/NLP confidence
    validation_status VARCHAR(30) DEFAULT 'pending'
        CHECK (validation_status IN ('pending','auto_approved','needs_review','approved','flagged','rejected')),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_land_records_khasra ON land_records(khasra_number);
CREATE INDEX idx_land_records_village ON land_records(village_unit_id);
CREATE INDEX idx_land_records_status ON land_records(validation_status);
CREATE INDEX idx_land_records_geo ON land_records USING GIST(geo_boundary);

-- ---------------------------------------------------------------------
-- 5. FIELD-LEVEL EXTRACTION + CONFIDENCE (per-field granularity for
--    the side-by-side verification UI / confidence heatmap)
-- ---------------------------------------------------------------------
CREATE TABLE extracted_fields (
    field_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID REFERENCES land_records(record_id) ON DELETE CASCADE,
    field_name VARCHAR(100) NOT NULL,                -- 'landowner_name','khasra_number', etc.
    raw_ocr_text TEXT,
    normalized_value TEXT,
    confidence_score NUMERIC(5,2),                   -- 0-100
    bounding_box JSONB,                              -- {x,y,width,height} on source image
    source_page INTEGER DEFAULT 1,
    is_manually_corrected BOOLEAN DEFAULT FALSE,
    corrected_by UUID REFERENCES users(user_id),
    corrected_at TIMESTAMPTZ
);

CREATE INDEX idx_extracted_fields_record ON extracted_fields(record_id);
CREATE INDEX idx_extracted_fields_confidence ON extracted_fields(confidence_score);

-- ---------------------------------------------------------------------
-- 6. VALIDATION RULES & CROSS-CHECK RESULTS
-- ---------------------------------------------------------------------
CREATE TABLE validation_rules (
    rule_id SERIAL PRIMARY KEY,
    rule_name VARCHAR(150) NOT NULL,
    rule_type VARCHAR(50),                            -- 'math_check','duplicate_check','format_check','geo_mismatch'
    rule_description TEXT,
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE validation_results (
    result_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID REFERENCES land_records(record_id) ON DELETE CASCADE,
    rule_id INTEGER REFERENCES validation_rules(rule_id),
    passed BOOLEAN,
    details JSONB,
    checked_at TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 7. HUMAN VERIFICATION / REVIEW QUEUE
-- ---------------------------------------------------------------------
CREATE TABLE review_queue (
    review_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID REFERENCES land_records(record_id) ON DELETE CASCADE,
    assigned_to UUID REFERENCES users(user_id),
    priority VARCHAR(20) DEFAULT 'normal' CHECK (priority IN ('low','normal','high','urgent')),
    status VARCHAR(30) DEFAULT 'pending' CHECK (status IN ('pending','in_review','resolved','escalated')),
    review_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    resolved_at TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- 8. IMMUTABLE AUDIT TRAIL (cryptographic hash-chained log)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id BIGSERIAL PRIMARY KEY,
    record_id UUID REFERENCES land_records(record_id),
    user_id UUID REFERENCES users(user_id),
    action VARCHAR(50) NOT NULL,                       -- 'created','field_corrected','approved','flagged','mutation'
    old_value JSONB,
    new_value JSONB,
    previous_hash VARCHAR(128),
    current_hash VARCHAR(128) NOT NULL,                -- sha256(previous_hash + action + new_value)
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_audit_record ON audit_log(record_id);

-- ---------------------------------------------------------------------
-- 9. EXTERNAL SYSTEM INTEGRATION (DILRMP / LRMS / GIS sync tracking)
-- ---------------------------------------------------------------------
CREATE TABLE external_sync_log (
    sync_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID REFERENCES land_records(record_id),
    target_system VARCHAR(50),                          -- 'DILRMP','LRMS','GIS'
    sync_status VARCHAR(30) DEFAULT 'pending',
    request_payload JSONB,
    response_payload JSONB,
    synced_at TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- 10. VIEW: dashboard summary stats (backs the analytics dashboard)
-- ---------------------------------------------------------------------
CREATE VIEW dashboard_summary AS
SELECT
    au.unit_name AS district_name,
    COUNT(lr.record_id) AS total_records,
    COUNT(*) FILTER (WHERE lr.validation_status = 'approved') AS approved_count,
    COUNT(*) FILTER (WHERE lr.validation_status = 'needs_review') AS pending_review_count,
    ROUND(AVG(lr.overall_confidence), 2) AS avg_confidence
FROM land_records lr
JOIN administrative_units au ON lr.district_unit_id = au.unit_id
GROUP BY au.unit_name;

-- Seed default roles
INSERT INTO roles (role_name, permissions) VALUES
    ('admin', '{"all": true}'),
    ('tehsildar', '{"verify": true, "approve": true}'),
    ('clerk', '{"upload": true, "view": true}'),
    ('viewer', '{"view": true}');
