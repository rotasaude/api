# Vincula e desvincula a equipe de um local de estoque (ADR 0045, Desvio 3).
# Vincular exige a Membership ATIVA do mesmo papel (`role_not_granted`) e, para
# `pharmacist`, um vínculo profissional ativo com CBO 2234* em qualquer unidade
# (`cbo_not_allowed`). O vínculo nunca se apaga: desvincular o revoga, uma vez
# (trigger), e vincular de novo grava outra linha. Evento
# `pharmacy.settings_changed` (subject `staff`) só com ids.
module Pharmacy
  module LinkStaff
    module_function

    # -> Result.ok(link:) | fail(:invalid_request, details: { path: }) |
    # fail(:not_found) | fail(:role_not_granted, path "role") | fail(:cbo_not_allowed, path "user_id") |
    # fail(:already_linked).
    def add(location:, user_id:, role:, by:)
      invalid = invalid_body(user_id, role)
      return invalid if invalid

      user = User.find_by(id: user_id)
      return Result.fail(:not_found) unless user&.active?

      StockLocationStaff.transaction(requires_new: true) do
        next refuse(:role_not_granted, "role") unless user.memberships.active.exists?(role: role)
        next refuse(:cbo_not_allowed, "user_id") if role == "pharmacist" && !pharmacist_cbo?(user)
        next Result.fail(:already_linked) if StockLocationStaff.active.exists?(stock_location_id: location.id, user_id: user.id, role: role)

        link = StockLocationStaff.create!(stock_location: location, user: user, role: role, granted_by_user: by, granted_at: Time.current)
        publish(location, user.id, by)
        Result.ok(link: link)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_linked)
    end

    # Vínculo ativo inexistente (inclusive o que já foi desfeito) → :not_found.
    def remove(location:, user_id:, role:, by:)
      invalid = invalid_body(user_id, role)
      return invalid if invalid

      StockLocationStaff.transaction(requires_new: true) do
        link = StockLocationStaff.active.lock.find_by(stock_location_id: location.id, user_id: user_id, role: role)
        next Result.fail(:not_found) unless link

        link.update!(revoked_at: Time.current, revoked_by_user: by)
        publish(location, link.user_id, by)
        Result.ok(link: link)
      end
    end

    def invalid_body(user_id, role)
      return refuse(:invalid_request, "role") unless Catalog::ROLES.include?(role)
      return refuse(:invalid_request, "user_id") unless user_id.is_a?(String)

      nil
    end

    # Todo 422 traz `problems` com ao menos um problema (regra do módulo).
    def refuse(error, path) = Result.fail(error, details: { path: path, problems: [ { path: path, error: error.to_s } ] })

    # Vínculo profissional ATIVO com CBO 2234* (farmacêutico), em qualquer unidade.
    def pharmacist_cbo?(user)
      prefix = ProfessionalLink.sanitize_sql_like(Catalog::PHARMACIST_CBO_PREFIX)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id })
                      .exists?([ "professional_links.cbo_code LIKE ?", "#{prefix}%" ])
    end

    def publish(location, staff_user_id, by)
      DomainEvents.publish("pharmacy.settings_changed", subject: "staff", stock_location_id: location.id,
                                                        staff_user_id: staff_user_id, user_id: by.id)
    end

    private_class_method :invalid_body, :refuse, :pharmacist_cbo?, :publish
  end
end
