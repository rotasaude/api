# Módulo 18 (ADR 0030): CIAP-2 na plataforma, profissionais da escuta,
# atendimentos aguardando (demanda espontânea ou horário) e o protocolo de
# acolhimento ativo, gravados direto (cenário de teste). Os caminhos reais são
# Terminology::Import, Attendances::CheckIn e o ciclo assinado.
module ScreeningHelpers
  CIAP2 = { "K86" => "Hipertensão sem complicações", "R05" => "Tosse", "A03" => "Febre",
            "N01" => "Cefaleia", "T90" => "Diabetes não insulino-dependente" }.freeze
  RULES = [
    { "when" => { "any" => [ { "gte" => ["vitals.systolic", 180] }, { "lt" => ["vitals.spo2", 90] } ] }, "color" => "red" },
    { "when" => { "any" => [ { "gte" => ["vitals.temperature_c", 39] }, { "gte" => ["vitals.capillary_glucose", 300] } ] },
      "color" => "yellow" },
    { "when" => { "eq" => ["complaint.ciap2", "R05"] }, "color" => "green" }
  ].freeze

  def ciap2_release!(codes = CIAP2)
    TerminologyRelease.active.find_by(kind: "ciap2") || begin
      release = TerminologyRelease.create!(kind: "ciap2", version: "2026.1", source_sha256: "c" * 64,
                                           imported_by: "rspec", imported_at: Time.current, status: "importing")
      codes.each { |code, description| Ciap2Code.create!(release: release, code: code, description: description) }
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  # Cidadão com perfil (nascimento e sexo), CPF e telefone únicos por n.
  def screening_citizen!(n, age: 40 + n, sex: "female")
    profiled_citizen!(age: age, sex: sex, phone: format("+55419%08d", 31_000_000 + n))
  end

  def reception! = (@reception ||= staff_with("recepcao-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier"))

  # Profissional da escuta com vínculo ativo na unidade (perfil pelo link_professional!).
  def screener!(unit, cbo: "223505", email: "escuta-#{SecureRandom.hex(3)}@cidade.gov.br")
    staff_with(email, "health_professional").tap { |user| link_professional!(user, unit, cbo: cbo) }
  end

  # Demanda espontânea: origem triagem, sem horário.
  def walk_in_attendance!(unit, citizen:, checked_in_at: Time.current)
    triage = completed_web_triage_for(citizen)
    Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: reception!,
                       checked_in_at: checked_in_at, check_in_method: "code")
  end

  # Origem horário marcado (fora do escopo walk_in).
  def scheduled_attendance!(unit, citizen:, checked_in_at: Time.current)
    request = triage_request!(citizen, unit: unit)
    shift = shift!(doctor_link!(unit), starts_at: 1.hour.from_now)
    appointment = appointment_row!(request, shift, starts_at: shift.starts_at)
    Attendance.create!(appointment: appointment, citizen: citizen, health_unit: unit, checked_in_by_user: reception!,
                       checked_in_at: checked_in_at, check_in_method: "code")
  end

  def appointment_type!(key = "consulta_enfermagem")
    AppointmentType.find_by(key: key) || type_row!(key, cbo: ["2235"], minutes: 15, origin: "platform")
  end

  def acolhimento!(rules = RULES, version: 1)
    ProtocolDefinition.create!(name: "acolhimento", version: version, status: "active",
                               definition: { "name" => "acolhimento", "version" => version, "kind" => "screening",
                                             "risk_rules" => rules })
  end

  def revision_params(**over)
    { "ciap2_code" => "K86", "vitals" => { "systolic" => 130, "diastolic" => 85 }, "final_color" => "green" }
      .merge(over.transform_keys(&:to_s))
  end

  # CNES na unidade, equipe com INE e os profissionais dados na equipe: a ficha pode nascer.
  def exportable_unit!(unit, *users)
    unit.update!(cnes: "1234567") if unit.cnes.blank?
    team = HealthTeam.find_by(health_unit: unit) ||
           HealthTeam.create!(health_unit: unit, ine: "0000123456", kind: "70", name: "ESF Centro")
    users.each do |user|
      link = user.professional.links.active.find_by!(health_unit: unit)
      HealthTeamMember.create!(professional: user.professional, health_team: team, cbo_code: link.cbo_code,
                               started_on: Time.zone.today - 30)
    end
    team
  end
end

RSpec.configure { |c| c.include ScreeningHelpers }
