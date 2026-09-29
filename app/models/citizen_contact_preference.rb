# app/models/citizen_contact_preference.rb
# Preferências de contato do cidadão (ADR 0024 §3.3): opt-in do SMS (desligado
# por padrão) e silêncio dos avisos. Ausência de linha = os dois desligados.
class CitizenContactPreference < ApplicationRecord
  self.primary_key = "citizen_id"

  belongs_to :citizen

  def self.for(citizen_id)
    find_by(citizen_id: citizen_id) || new(citizen_id: citizen_id)
  end
end
