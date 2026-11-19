-- IaC security: the repository to check and the data tier table of the production account
-- (IaC security rule-spec "데이터 등급"). Values differ per environment, so they are not a migration.
-- Path analysis ends paths at these assets; the State check reads the TFSTATE bucket's readers.
-- Run on the dashboard host from /opt/logssey as root (safe to run again):
--   docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d logssey < iac-data-assets.sql
-- Checked against the account on 2026-11-18 (read only). Not listed: logssey-prod-s3-k8s-oidc (public
-- OIDC discovery documents) and the cmstudy-* buckets (not Logssey resources).
BEGIN;

INSERT INTO iac_repos (full_name, default_branch, environment)
VALUES ('Logssey/infrastructure', 'main', 'PROD')
ON CONFLICT (full_name) DO NOTHING;

INSERT INTO iac_data_assets (arn, kind, tier) VALUES
    -- Tier 1: database, Terraform state, secrets
    ('arn:aws:rds:ap-northeast-1:794386801311:db:logssey-prod-rds', 'RDS', 1),
    ('arn:aws:s3:::logssey-prod-s3-tfstate', 'TFSTATE', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:logssey/prod/grafana-TqYT6P', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:logssey/prod/grafana-oauth-cE8mj7', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:rds!db-c78baf92-e022-4c45-91d8-2a27265e7c51-ZMZtyJ', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:reused-reused-temp-pentest-2-secret-8F12M7IOC-u8QR3c', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:reused-reused-temp-pentest-secret-8F12KM328-wfwDUc', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:reused/prod/api-ONfjwj', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:reused/prod/chat-dvg9mY', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:logssey/dashboard/ai/claude-api-key-zUuvzF', 'SECRET', 1),
    ('arn:aws:secretsmanager:ap-northeast-1:794386801311:secret:logssey/dashboard/source-credentials/github-45a0b5422ac01076ecc6ca77de4f1c561183b8ab8f39e97b7980ed9112813dc5-bJKXpO', 'SECRET', 1),
    -- Tier 2: images and logs
    ('arn:aws:s3:::logssey-prod-s3-images', 'S3', 2),
    ('arn:aws:s3:::logssey-prod-loki-chunks', 'S3', 2),
    ('arn:aws:s3:::logssey-prod-loki-ruler', 'S3', 2)
ON CONFLICT (arn) DO UPDATE SET kind = EXCLUDED.kind, tier = EXCLUDED.tier, updated_at = now();

SELECT tier, kind, count(*) FROM iac_data_assets GROUP BY 1, 2 ORDER BY 1, 2;
SELECT full_name, default_branch, environment, enabled FROM iac_repos;

COMMIT;
