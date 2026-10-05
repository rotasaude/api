# Sugestão nascida da conclusão de uma triagem (ADR 0027; spec 2026-10-05
# §3.3, §5.3). pending → taken | expired, garantido por trigger; no máximo uma
# pendente por protocolo por par (índice único parcial).
class TriageSuggestion < ApplicationRecord
  belongs_to :citizen
  belongs_to :source_triage, class_name: "Triage"
  belongs_to :taken_triage, class_name: "Triage", optional: true

  enum :status, { pending: "pending", taken: "taken", expired: "expired" }, prefix: true

  validates :protocol_name, presence: true
end
