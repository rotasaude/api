# app/services/screenings/authorization.rb
# Regra da escuta (ADR 0030; spec §3.2): papel health_professional, vínculo
# ativo com a unidade do atendimento e CBO permitido. Chame DENTRO da
# transação do comando: o FOR SHARE no vínculo faz o encerramento esperar,
# como Professionals::ClinicalAuthorization.
module Screenings
  module Authorization
    module_function

    def check(user:, health_unit_id:)
      return [ :missing_role, nil ] unless user&.has_role?("health_professional")

      links = ProfessionalLink.active.joins(:professional)
                              .where(professionals: { user_id: user.id }, health_unit_id: health_unit_id.to_s)
                              .lock("FOR SHARE OF professional_links").order(:started_at, :id).to_a
      return [ :missing_link, nil ] if links.empty?

      allowed = links.select { |link| Cbos.allowed?(link.cbo_code) }
      return [ :cbo_not_allowed, nil ] if allowed.empty?

      [ :ok, allowed.find { |link| Ledi::ScreeningMapping.miai_cbo?(link.cbo_code) } || allowed.first ]
    end
  end
end
