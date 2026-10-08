# app/services/consultations/authorization.rb
# Papel health_professional, vínculo ativo e CBO permitido (ADR 0031). Chame
# DENTRO da transação do comando: o FOR SHARE no vínculo faz o encerramento
# esperar (como Professionals::ClinicalAuthorization).
module Consultations
  module Authorization
    module_function

    def link_for(user:, health_unit_id:)
      return [ :missing_role, nil ] unless user&.has_role?("health_professional")

      links = active_links(user).where(health_unit_id: health_unit_id.to_s).lock("FOR SHARE OF professional_links").to_a
      pick(links)
    end

    # Para a abertura e o adendo de terceiro: um vínculo permitido em qualquer unidade.
    def any_allowed_link(user:)
      return [ :missing_role, nil ] unless user&.has_role?("health_professional")

      pick(active_links(user).to_a)
    end

    def any_link(user:) = any_allowed_link(user: user).first

    def active_links(user)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id }).order(:started_at, :id)
    end

    def pick(links)
      return [ :missing_link, nil ] if links.empty?

      allowed = links.find { |link| Cbos.allowed?(link.cbo_code) }
      allowed ? [ :ok, allowed ] : [ :cbo_not_allowed, nil ]
    end
    private_class_method :active_links, :pick
  end
end
