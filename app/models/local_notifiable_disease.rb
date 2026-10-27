# Doença de notificação acrescentada pela cidade (ADR 0043); a lista nacional
# mora na plataforma (NotifiableDisease). Nunca é apagada (trigger): desativa-se.
# O formato do código, o prazo e a repetição são CHECKs do banco; a validação
# com mensagem é do Surveillance::SaveLocalDisease.
class LocalNotifiableDisease < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"

  scope :active_diseases, -> { where(active: true) }
end
