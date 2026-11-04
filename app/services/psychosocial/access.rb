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

    # Quem encaminha ao CAPS (contrato §4): health_professional com vínculo
    # ativo numa unidade ativa que NÃO é CAPS; o mais antigo (started_at, id)
    # dá a unidade de origem. -> ProfessionalLink | nil
    def referrer_link(user)
      return nil unless roles?(user, %w[health_professional])

      ProfessionalLink.active.joins(:professional, :health_unit)
                      .where(professionals: { user_id: user.id }, health_units: { active: true })
                      .where.not(health_units: { kind: "caps" }).order(:started_at, :id).first
    end

    # Busca de pessoa e duplicados do CAPS (contrato P30): lotado em algum CAPS
    # ativo ou encaminhador da UBS.
    def person_searcher?(user) = staffed_unit_ids(user).any? || referrer_link(user).present?

    # { user_id => CBO do vínculo ativo mais antigo no CAPS } — o <pro> das
    # leituras (técnico de referência), sem exigir o papel do CAPS.
    def cbos(user_ids, health_unit_id)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user_ids.uniq }, health_unit_id: health_unit_id)
                      .order(:started_at, :id).pluck("professionals.user_id", :cbo_code)
                      .each_with_object({}) { |(user_id, cbo), out| out[user_id] ||= cbo }
    end

    def roles?(user, roles) = user.present? && user.memberships.active.where(role: roles).exists?

    def caps_links(user)
      ProfessionalLink.active.joins(:professional, :health_unit)
                      .where(professionals: { user_id: user.id }, health_units: { kind: "caps" })
    end

    private_class_method :roles?, :caps_links
  end
end
