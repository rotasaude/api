# Emenda ADR-0023 ao ADR-0009: linhas platform-scope (login/MFA/provisioning)
# têm municipality_id NULL e só são visíveis sob bypass.
class DomainEventsMunicipalityNullable < ActiveRecord::Migration[8.1]
  def change
    change_column_null :domain_events, :municipality_id, true
  end
end
