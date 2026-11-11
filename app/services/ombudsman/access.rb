# Papéis e destinos da ouvidoria (ADR 0051; contrato §1, §6, §7). O padrão de
# Psychosocial::Access: o papel vem da membership ativa; o respondente só
# alcança os destinos em que tem linha ativa em ombudsman_responders E o papel
# ombudsman_responder ainda ativo (revogado o papel, a linha não conta).
module Ombudsman
  module Access
    STAFF_ROLES = %w[ombudsman_staff ombudsman].freeze

    module_function

    # Técnico da ouvidoria ou o ouvidor (que faz tudo do técnico).
    def staff?(user) = roles?(user, STAFF_ROLES)
    def ombudsman?(user) = roles?(user, %w[ombudsman])
    def responder?(user) = roles?(user, %w[ombudsman_responder])
    def admin?(user) = roles?(user, %w[municipal_admin])
    # Leitura da configuração (setores): o administrador, o técnico e o ouvidor.
    def config_reader?(user) = admin?(user) || staff?(user)

    # -> { department_ids: [uuid], health_unit_ids: [uuid] }: os destinos das
    # linhas ativas do usuário, só enquanto ele tem o papel de respondente.
    def destinations(user)
      return { department_ids: [], health_unit_ids: [] } unless responder?(user)

      rows = OmbudsmanResponder.active.where(user_id: user.id)
      { department_ids: rows.where.not(department_id: nil).distinct.pluck(:department_id),
        health_unit_ids: rows.where.not(health_unit_id: nil).distinct.pluck(:health_unit_id) }
    end

    # As linhas de respondente que contam: linha ativa, papel de respondente
    # ativo e usuário não desativado. Única definição, de responder_ids_for e
    # de destinations_with_responder.
    def responder_rows
      OmbudsmanResponder.active.joins(user: :memberships).where(users: { deactivated_at: nil })
                        .merge(Membership.active.where(role: "ombudsman_responder"))
    end

    # -> [uuid] dos usuários que respondem o destino (um dos dois ids).
    def responder_ids_for(department_id: nil, health_unit_id: nil)
      destination = department_id ? { department_id: department_id } : { health_unit_id: health_unit_id }
      return [] if destination.values.first.blank?

      responder_rows.where(destination).distinct.pluck(:user_id)
    end

    # -> { department_ids: [uuid], health_unit_ids: [uuid] }: os destinos que
    # têm ao menos um respondente (em lote, para a lista de opções).
    def destinations_with_responder
      { department_ids: responder_rows.where.not(department_id: nil).distinct.pluck(:department_id),
        health_unit_ids: responder_rows.where.not(health_unit_id: nil).distinct.pluck(:health_unit_id) }
    end

    def roles?(user, roles) = user.present? && user.memberships.active.where(role: roles).exists?

    private_class_method :roles?
  end
end
