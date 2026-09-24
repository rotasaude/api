# Validação presencial de um par (CPF, celular) — spec 2026-09-24 §3. Só
# acréscimo: desfazer preenche revoked_* uma vez (trigger em city_triggers.sql).
class CitizenVerification < ApplicationRecord
  belongs_to :citizen
  belongs_to :verified_by_user, class_name: "User"
  belongs_to :revoked_by_user, class_name: "User", optional: true

  scope :active, -> { where(revoked_at: nil) }

  def active?
    revoked_at.nil?
  end
end
