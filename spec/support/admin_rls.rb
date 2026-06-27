# Helpers para specs que tocam tabelas com RLS (ADR-0019) de forma cross-tenant.
#
# Em test, `use_transactional_tests = true` (default) coage as conexões multi-DB
# a compartilharem a conexão primary (rota_app) dentro da transação do exemplo,
# anulando o BYPASSRLS do `connected_to(role: :admin)`. Specs que precisam da
# conexão admin REAL (escrever/ler cross-tenant sem SET LOCAL) devem:
#   - declarar `self.use_transactional_tests = false`
#   - criar/ler fixtures dentro de `as_admin { ... }`
#   - limpar as tabelas em before/after via `clean_admin_tables`
module AdminRls
  # Ordem FK-safe (filhos antes de pais). DELETE é no-op em tabela vazia.
  CLEAN_TABLES = %w[
    report_snapshots triages consents inbound_messages outbound_messages domain_events
    processed_events dashboard_metrics
    alert_recipients consent_terms conversations protocol_definitions
    municipality_channels authors invitations memberships sessions
    identities municipalities users
  ].freeze

  def as_admin(&blk)
    ApplicationRecord.connected_to(role: :admin, &blk)
  end

  def clean_admin_tables
    ApplicationRecord.connected_to(role: :admin) do
      conn = ApplicationRecord.connection
      CLEAN_TABLES.each { |t| conn.execute("DELETE FROM #{t}") }
    end
  end
end

RSpec.configure do |config|
  config.include AdminRls
end
