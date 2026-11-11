# apps/api/app/models/membership.rb
# Memberships (ADR-0012), no banco da cidade. Append-only: revogar = end-date (revoked_at).
# Só papéis locais: o operador de plataforma saiu desta tabela (Operator, na
# plataforma — spec banco-por-cidade §5), e com ele a coluna de município e o
# CHECK de operador global. ROLES espelha ck_memberships_role do db/city_schema.rb.
class Membership < ApplicationRecord
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier driver exam_provider exam_regulator
             health_professional lab_releaser lab_staff municipal_admin ombudsman ombudsman_responder ombudsman_staff
             pharmacist pharmacy_assistant protocol_author protocol_publisher protocol_reviewer psychosocial_lead
             psychosocial_staff stock_keeper surveillance tfd_committee transport_dispatcher viewer].freeze

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
  # exam_regulator e exam_provider (ADR 0036): veem o nome do paciente junto
  # com o exame — step-up; o mantenedor não concede.
  # lab_staff e lab_releaser (ADR 0037): veem nome e amostra do paciente; o
  # liberador assina laudo — step-up; o mantenedor não concede.
  # billing_clerk (ADR 0039): fecha competência e baixa o arquivo BPA com
  # nome, CPF e nascimento do paciente — step-up; o mantenedor não concede.
  # surveillance (ADR 0043): lê nome e doença de notificação compulsória —
  # step-up; o mantenedor não concede.
  # care_regulator (ADR 0044): lê nome, CID e justificativa do pedido de
  # regulação e autoriza vaga — step-up; o mantenedor não concede.
  # pharmacist e pharmacy_assistant (ADR 0045): veem nome do paciente e o que
  # ele retira; o farmacêutico dispensa controlado — step-up; o mantenedor não
  # concede. stock_keeper NÃO entra: só estoque, sem dado pessoal (P17).
  # transport_dispatcher (ADR 0048): vê nome, telefone e embarque do paciente
  # e monta a viagem; tfd_committee: lê CID e justificativa do laudo do TFD e
  # registra pagamento — step-up; o mantenedor não concede. driver NÃO entra:
  # só as próprias viagens do dia, sem dado clínico.
  # psychosocial_staff e psychosocial_lead (ADR 0049): leem CID, substâncias,
  # evolução e PTS do CAPS em que estão lotados; a coordenação fecha e reabre
  # o mês e cancela ação de mês fechado — step-up; o mantenedor não concede.
  # ombudsman (ADR 0051): abre a identidade preservada e arquiva — step-up para
  # conceder; o mantenedor não concede. ombudsman_staff (ADR 0051 + §16 U3): lê
  # texto de saúde e identidade no modo identificado — também step-up.
  # ombudsman_responder NÃO entra: só responde ao encaminhamento do seu setor.
  PRIVILEGED_ROLES = %w[municipal_admin protocol_reviewer citizen_verifier health_professional
                        campaign_manager exam_regulator exam_provider lab_staff lab_releaser billing_clerk surveillance
                        care_regulator pharmacist pharmacy_assistant transport_dispatcher tfd_committee
                        psychosocial_staff psychosocial_lead ombudsman ombudsman_staff].freeze

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
