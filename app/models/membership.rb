# apps/api/app/models/membership.rb
# Memberships (ADR-0012), no banco da cidade. Append-only: revogar = end-date (revoked_at).
# Só papéis locais: o operador de plataforma saiu desta tabela (Operator, na
# plataforma — spec banco-por-cidade §5), e com ele a coluna de município e o
# CHECK de operador global. ROLES espelha ck_memberships_role do db/city_schema.rb.
class Membership < ApplicationRecord
  ROLES = %w[analyst campaign_manager citizen_verifier health_professional municipal_admin protocol_author
             protocol_publisher protocol_reviewer viewer].freeze

  # Papéis que o mantenedor da API de manutenção nunca concede nem convida
  # (spec de assinaturas §7): quem aprova protocolo e quem concede aprovação.
  # Com eles, o superusuário criaria as duas contas de revisor e assinaria.
  # citizen_verifier (spec da validação presencial §2.1): marca identidade de
  # cidadão como verificada — conceder e revogar exigem step-up, e o
  # mantenedor não concede.
  # health_professional (spec 2026-09-25 §2.1): chama e registra desfecho
  # clínico — step-up para conceder; o mantenedor não concede.
  # campaign_manager (ADR 0024): monta públicos com dado de saúde e fala em
  # nome da secretaria — step-up para conceder; o mantenedor não concede.
  # analyst (ADR 0025) NÃO entra: só lê agregados já suprimidos — sem step-up.
  PRIVILEGED_ROLES = %w[municipal_admin protocol_reviewer citizen_verifier health_professional
                        campaign_manager].freeze

  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true

  validates :role, inclusion: { in: ROLES }
  validates :granted_at, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def revoke!(by: nil)
    return if revoked_at.present?
    update!(revoked_at: Time.current)
  end
end
