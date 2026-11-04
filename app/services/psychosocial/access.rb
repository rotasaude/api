# Lotação no CAPS (ADR 0049; plano, Desvio 2; contrato §1): a pessoa está
# lotada quando tem o papel do CAPS (psychosocial_staff, ou psychosocial_lead,
# que implica o primeiro) E um professional_links ativo no CAPS. O vínculo
# ativo mais antigo (started_at, id) dá o CBO da ação. Vínculo em unidade que
# não é CAPS nunca é lotação. Faturista, administrador e analista leem a lista
# de todos os CAPS (contrato P4), sem lotação.
module Psychosocial
  module Access
    STAFF_ROLES = %w[psychosocial_staff psychosocial_lead].freeze
    ALL_UNITS_ROLES = %w[billing_clerk municipal_admin analyst].freeze

    module_function

    def staff?(user) = roles?(user, STAFF_ROLES)
    def lead?(user) = roles?(user, %w[psychosocial_lead])
    def all_units?(user) = roles?(user, ALL_UNITS_ROLES)

    # -> ProfessionalLink | nil
    def link(user, health_unit_id)
      return nil if health_unit_id.blank? || !staff?(user)

      caps_links(user).where(health_unit_id: health_unit_id).order(:started_at, :id).first
    end

    # -> [uuid] dos CAPS ativos em que a pessoa está lotada.
    def staffed_unit_ids(user)
      return [] unless staff?(user)

      caps_links(user).where(health_units: { active: true }).distinct.pluck(:health_unit_id)
    end

    # Registro com health_unit_id: só quem está lotado naquele CAPS.
    def can_read?(user, record) = link(user, record&.health_unit_id).present?

    def roles?(user, roles) = user.present? && user.memberships.active.where(role: roles).exists?

    def caps_links(user)
      ProfessionalLink.active.joins(:professional, :health_unit)
                      .where(professionals: { user_id: user.id }, health_units: { kind: "caps" })
    end

    private_class_method :roles?, :caps_links
  end
end
