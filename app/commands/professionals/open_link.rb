# Abre o vínculo do profissional com a unidade (ADR 0021): CBO vigente,
# coerente com o conselho do perfil, unidade ativa, um ativo por (profissional,
# unidade, CBO). Início = agora, sem data retroativa. Abrir concede autoridade
# clínica naquela unidade (F-10.5): quem chama já passou por step-up.
#
# Ordem de travas: unidade -> profissional -> vínculo (D: race do conselho).
# FOR UPDATE no profissional depois da unidade e antes de ler o conselho:
# uma troca de conselho concorrente (UpdateProfile, que só trava o
# profissional) espera ou é vista, então a checagem de coerência nunca lê um
# conselho que está sendo trocado.
module Professionals
  class OpenLink
    def self.call(professional:, health_unit_id:, cbo_code:, by:)
      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock_active!(health_unit_id)
        professional.lock!

        entry = Cbo.find(cbo_code)
        next Result.fail(:invalid_cbo) if entry.nil? || entry.deprecated
        next Result.fail(:council_mismatch) if entry.council && entry.council != professional.council

        if professional.links.active.exists?(health_unit_id: health_unit_id, cbo_code: entry.code)
          next Result.fail(:already_linked)
        end

        link = ProfessionalLink.create!(professional: professional, health_unit_id: health_unit_id, cbo_code: entry.code,
                                        started_at: Time.current, started_by_user: by)
        DomainEvents.publish("professional.linked", professional_link_id: link.id, professional_id: professional.id,
                                                    health_unit_id: link.health_unit_id, by_user_id: by.id)
        Result.ok(link: link)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_linked)
    end
  end
end
