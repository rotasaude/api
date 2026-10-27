# Uma versão da Lista Nacional de Notificação Compulsória (módulo 25; ADR 0043).
# Imutável (trigger); a vigente num dia é a de maior `version` com effective_from <= dia.
class NotifiableDiseaseVersion < PlatformRecord
  has_many :diseases, class_name: "NotifiableDisease", foreign_key: :list_version_id, inverse_of: :list_version

  def readonly? = persisted?
end
