# Doença de uma versão da lista nacional. Imutável (trigger).
class NotifiableDisease < PlatformRecord
  belongs_to :list_version, class_name: "NotifiableDiseaseVersion", inverse_of: :diseases

  def readonly? = persisted?
end
