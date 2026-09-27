# Regra da chamada e do desfecho clínico (ADR 0021; F-10.5): papel
# health_professional ativo E vínculo ativo com a unidade do atendimento, em
# qualquer CBO. Chame DENTRO da transação do comando: o FOR SHARE no vínculo
# faz o encerramento (EndLink, FOR UPDATE) esperar o ato em curso, ou ser
# visto por ele. Turno nunca entra aqui — falha de escala não bloqueia
# atendimento.
module Professionals
  module ClinicalAuthorization
    module_function

    def check(user:, health_unit_id:)
      return :missing_role unless user&.has_role?("health_professional")

      linked = ProfessionalLink.active.joins(:professional)
                               .where(professionals: { user_id: user.id }, health_unit_id: health_unit_id.to_s)
                               .lock("FOR SHARE OF professional_links").pick(:id)
      linked ? :ok : :missing_link
    end
  end
end
