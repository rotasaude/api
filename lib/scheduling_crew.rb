require_relative "professional_crew"
require_relative "triage_catalog_crew"

# Semente de dev do módulo 17 (spec 2026-10-05 §10). Dev é fictício mas imita o
# real: a base de tipos copiada; em Curitiba, o modelo "Manhã" (demanda do dia
# 7–9h, consultas médicas 9–11h, bloqueio 11–12h) nos turnos da médica da
# semente na UBS Jardim das Flores; turnos da semana (os dias úteis do
# ProfessionalCrew) para a médica (7–13h) e a enfermeira (7–19h, sem modelo:
# vagas de consulta de enfermagem pelo CBO); e "Saúde do idoso" com a regra de
# agendamento (rotina, 30 dias) numa versão nova assinada de verdade.
# Idempotente. Roda depois do ProfessionalCrew e do TriageCatalogCrew.
class SchedulingCrew
  UNIT = "UBS Jardim das Flores"
  TEMPLATE_NAME = "Manhã: demanda do dia, consultas e bloqueio"
  BLOCKS = [
    { "starts" => "07:00", "ends" => "09:00", "kind" => "walk_in" },
    { "starts" => "09:00", "ends" => "11:00", "kind" => "bookable", "appointment_type_key" => "consulta_medica" },
    { "starts" => "11:00", "ends" => "12:00", "kind" => "blocked" }
  ].freeze
  SCHEDULING = [ { "when" => { "gte" => ["outcome.score", 3] }, "appointment_type" => "consulta_medica",
                   "priority" => "routine", "due_in_days" => 30 } ].freeze
  ELDERLY = TriageCatalogCrew::ELDERLY

  class << self
    def seed_current_city(slug:)
      Scheduling::AppointmentTypes.seed_platform!
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      unit = HealthUnit.find_by!(name: UNIT)
      medica = link_for("profissional", slug, unit, "225125")
      enfermeira = link_for("enfermeira", slug, unit, "223505")
      template = slug == "curitiba" ? ensure_template!(admin) : nil
      new_shifts = ensure_week!(medica, admin, 7, 13, template) + ensure_week!(enfermeira, admin, 7, 19, nil)
      templated = template ? attach!(medica, template, admin) : 0
      protocol = ensure_protocol!(slug)
      { types: AppointmentType.count, template: template&.name, new_shifts: new_shifts, templated: templated,
        protocol: "#{protocol.name} v#{protocol.version}" }
    end

    private

    def link_for(prefix, slug, unit, cbo)
      professional = User.find_by!(email_address: "#{prefix}@#{slug}.demo").professional
      professional.links.active.find_by!(health_unit: unit, cbo_code: cbo)
    end

    # O ProfessionalCrew só lança a semana quando o vínculo não tem turno futuro
    # nenhum; rodada dias depois, sobra uma semana parcial. Aqui cada dia útil
    # sem turno no vínculo ganha o seu (já com o modelo, quando há).
    def ensure_week!(link, admin, from_hour, to_hour, template)
      ProfessionalCrew.business_days.count do |day|
        starts = ProfessionalCrew.at(day, from_hour)
        ends = ProfessionalCrew.at(day, to_hour)
        next false if link.shifts.valid_shifts.where("starts_at < ? AND ends_at > ?", ends, starts).exists?

        result = Professionals::ScheduleShift.call(link: link, starts_at: starts, ends_at: ends, by: admin,
                                                   schedule_template_id: template&.id)
        next false if result.reason == :shift_overlap # turno noutra unidade no mesmo horário

        raise "semente da agenda: turno recusado (#{result.reason})" if result.failure?

        true
      end
    end

    def ensure_template!(admin)
      existing = ScheduleTemplate.find_by(name: TEMPLATE_NAME)
      return existing if existing

      result = Scheduling::SaveTemplate.call(attrs: { "name" => TEMPLATE_NAME, "fit_in_limit" => 2, "blocks" => BLOCKS.map(&:dup) },
                                             by: admin)
      raise "semente da agenda: modelo recusado (#{result.reason} #{result.details})" if result.failure?

      result.payload[:template]
    end

    # Os turnos futuros da médica lançados antes (pelo ProfessionalCrew) ganham o modelo.
    def attach!(link, template, admin)
      link.shifts.valid_shifts.where("starts_at > ?", Time.current).where(schedule_template_id: nil).count do |shift|
        result = Professionals::SetShiftTemplate.call(shift: shift, schedule_template_id: template.id, by: admin)
        raise "semente da agenda: modelo no turno recusado (#{result.reason})" if result.failure?

        true
      end
    end

    # Versão nova = a ativa + scheduling; retoma a versão pendente que já o leva.
    def ensure_protocol!(slug)
      active = ProtocolDefinition.find_by!(name: ELDERLY, status: "active")
      return active if active.definition["scheduling"] == SCHEDULING

      versions = ProtocolDefinition.where(name: ELDERLY)
      pending = versions.where.not(status: %w[active retired]).find { |v| v.definition["scheduling"] == SCHEDULING }
      version = pending&.version || (versions.maximum(:version) + 1)
      TriageCatalogCrew.run_cycle!(slug, ELDERLY, version,
                                   active.definition.merge("version" => version, "scheduling" => SCHEDULING))
    end
  end
end
