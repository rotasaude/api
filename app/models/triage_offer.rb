# Linha do catálogo da cidade (ADR 0027; spec 2026-10-05 §3.2). Só restringe a
# elegibilidade assinada (soma com E). Escrita só por Triages::SetOffer.
class TriageOffer < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"

  validates :protocol_name, presence: true, uniqueness: true
end
