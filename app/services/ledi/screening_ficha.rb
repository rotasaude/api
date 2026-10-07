# A ficha da escuta (ADR 0030; spec §5). Nasce só de escuta concluída, só com
# a exportação utilizável e record_mode diferente de off, e uma vez por
# escuta (qualquer tipo de ficha). Sem identificação completa, não nasce:
# fica em ledi_generation_failures com os motivos (lista fechada), e a próxima
# tentativa que der certo resolve. O CBO decide: nível superior (tabela do
# MIAI) → Atendimento Individual; técnico/auxiliar de enfermagem →
# Procedimentos — com ou sem aferição (decisão D10 do product owner,
# 2026-10-07: sem aferição, só a marca de escuta inicial).
module Ledi
  module ScreeningFicha
    SOURCE_TYPE = "Screening".freeze

    module_function

    def exportable?(city)
      Platform::Features.usable?(city, :ledi_export) && Platform::Features.settings(city)[:record_mode] != "off"
    end

    def generate(screening, city: Current.city)
      return :skipped unless screening.completed?
      return :unusable unless exportable?(city)
      return :exists if LediOutboxEntry.exists?(source_type: SOURCE_TYPE, source_id: screening.id)

      ficha, reasons = build(screening)
      return record_failure!(screening, reasons) if reasons.any?

      resolve_failure!(screening)
      return :nothing unless ficha

      Ledi::Enqueue.call(ficha, city: city) ? :enqueued : :unusable
    end

    # [ficha, []] | [nil, motivos] | [nil, []] (CBO fora das duas fichas:
    # Screenings::Cbos não deixa acontecer; sem ficha e sem "não gerada").
    def build(screening)
      kind = ficha_kind(screening.cbo_code)
      return [ nil, [] ] unless kind

      revision = screening.current_revision
      attendance = screening.attendance
      unit = attendance.health_unit
      professional = screening.professional_link.professional
      citizen = attendance.citizen
      ine = team_ine(professional, unit)
      birth = birth_date(citizen)

      reasons = []
      reasons << "unit_without_cnes" if unit.cnes.blank?
      reasons << "professional_without_team" if ine.nil?
      reasons << "professional_without_cns" unless Professionals::Cns.valid?(professional.cns)
      reasons << "citizen_without_birth_date" if birth.nil?
      reasons << "citizen_without_sex" unless Citizen::SEXES.include?(citizen.sex)
      if kind == :initial_listening && !Ciap2Code.exists?(release_id: revision.ciap2_release_id, code: revision.ciap2_code)
        reasons << "unknown_ciap2"
      end
      return [ nil, reasons ] if reasons.any?

      identity = Ledi::Fichas::ScreeningIdentity.new(
        cnes: unit.cnes, ine: ine, professional_cns: professional.cns, cbo: screening.cbo_code,
        citizen_cpf: citizen.cpf, birth_date: birth, sex: citizen.sex, started_at: screening.started_at,
        ended_at: [ revision.created_at, screening.started_at ].max, ibge_code: CityProfile.current&.ibge_code
      )
      ficha = if kind == :initial_listening
                Ledi::Fichas::InitialListening.new(identity: identity, revision: revision,
                                                   destination: screening.destination, source_id: screening.id)
              else
                Ledi::Fichas::ScreeningProcedures.new(identity: identity, revision: revision, source_id: screening.id)
              end
      [ ficha, [] ]
    end

    def ficha_kind(cbo)
      if Ledi::ScreeningMapping.miai_cbo?(cbo) then :initial_listening
      elsif Ledi::ScreeningMapping.procedures_cbo?(cbo) then :procedures
      end
    end

    def record_failure!(screening, reasons)
      failure = LediGenerationFailure.unresolved.find_by(source_type: SOURCE_TYPE, source_id: screening.id)
      if failure
        failure.update!(reason_codes: reasons) unless failure.reason_codes == reasons
      else
        failure = ApplicationRecord.transaction(requires_new: true) do
          LediGenerationFailure.create!(source_type: SOURCE_TYPE, source_id: screening.id, reason_codes: reasons)
        end
        DomainEvents.publish("ledi.generation_failed", failure_id: failure.id, source_type: SOURCE_TYPE,
                                                       source_id: screening.id)
      end
      :failed
    rescue ActiveRecord::RecordNotUnique
      :failed # outra execução (fechamento × varredor) registrou no mesmo instante
    end

    def resolve_failure!(screening)
      LediGenerationFailure.unresolved.where(source_type: SOURCE_TYPE, source_id: screening.id)
                           .update_all(resolved_at: Time.current, updated_at: Time.current)
    end

    # INE da equipe ativa da unidade em que o profissional está (eSF/eAP).
    def team_ine(professional, unit)
      HealthTeamMember.active.joins(:health_team)
                      .where(professional_id: professional.id, health_teams: { health_unit_id: unit.id, active: true })
                      .order(:started_on, :id).pick("health_teams.ine")
    end

    def birth_date(citizen)
      citizen.birth_date.present? ? Date.iso8601(citizen.birth_date) : nil
    rescue Date::Error
      nil
    end
  end
end
