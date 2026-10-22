# Módulo 23 (ADR 0040): cidade com o prontuário e care_lines, catálogo-base,
# linha adotada, equipe, profissionais e pacientes com problema ativo.
# Cenário de teste: os caminhos reais são CareLines::SaveLine, Enroll e o
# 19a (Consultations::Finalize) para o problema.
module CareLineHelpers
  def care_city!
    city = clinical_city!
    cid10_release!
    ciap2_release!(ScreeningHelpers::CIAP2.merge("W78" => "Gravidez", "K87" => "Hipertensão com complicações",
                                                 "W82" => "Aborto espontâneo", "W18" => "Puerpério",
                                                 "W14" => "Contracepção, outros"))
    Platform::Features.set!(city: city, key: "care_lines", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  def care_lines_loaded! = (CareLineTemplate.exists? || CareLines::Templates::Load.call)

  def care_admin! = (@care_admin ||= staff_with("admin-linhas-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))

  def adopted_line!(key)
    care_lines_loaded!
    CareLine.find_by(template_key: key) || begin
      t = CareLineTemplate.current(key)
      CareLine.create!(source: "template", template_key: key, template_version: t.version, indicator: t.indicator, name: t.name,
                       eligibility: t.eligibility, practices: t.practices, declared_condition: t.declared_condition,
                       updated_by_user: care_admin!)
    end
  end

  def care_unit!(name = "UBS Linhas #{SecureRandom.hex(2)}") = create_unit(name)
  def care_doctor!(unit) = doctor!(unit) # 225125
  def care_nurse!(unit) = screener!(unit, cbo: "223505")

  def care_team!(unit, *users)
    team = HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "70",
                              name: "ESF #{unit.name}")
    users.each do |user|
      link = user.professional.links.active.find_by!(health_unit: unit)
      HealthTeamMember.create!(professional: user.professional, health_team: team, cbo_code: link.cbo_code, started_on: Time.zone.today - 30)
    end
    team
  end

  # Paciente (caminho real: par validado + Patients::Resolve) com problemas
  # ativos gravados direto (evento + estado, como Patients::ApplyProblemEvent
  # exige pelo trigger, sem consulta: addendum/consulta nulos não passam, por
  # isso o problema nasce de uma consulta finalizada mínima quando pedido).
  def care_patient!(age:, sex:, problems: [], unit: nil, doctor: nil, gender_identity: nil)
    patient, citizen = exam_patient!(exam_seq!, age: age, sex: sex)
    citizen.update!(gender_identity: gender_identity) if gender_identity
    Patients::Resolve.refresh!(patient)
    return patient.reload if problems.empty?

    unit ||= care_unit!
    doctor ||= care_doctor!(unit)
    evaluated = problems.map { |terminology, code| { "terminology" => terminology, "code" => code, "action" => "add" } }
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, evaluated_problems: evaluated, exam_requests: [])
    patient.reload
  end

  def care_enrollment!(patient:, line:, team:, by:, anchor_date: nil, enrolled_at: Time.current)
    CareLineEnrollment.create!(patient: patient, care_line: line, team: team, enrolled_by_user: by, enrolled_at: enrolled_at,
                               source: "manual", anchor_date: anchor_date&.iso8601)
  end

  def care_neighborhood!(*units)
    neighborhood = Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual")
    units.each { |unit| NeighborhoodCoverage.create!(neighborhood: neighborhood, health_unit: unit) }
    neighborhood
  end

  # Par validado que nunca consultou (sem paciente).
  def care_citizen!(age:, sex:, neighborhood: nil, gender_identity: nil)
    citizen = verified_citizen!(exam_seq!, age: age, sex: sex)
    citizen.update!(neighborhood: neighborhood, gender_identity: gender_identity)
    citizen
  end

  # Escuta concluída (caminho real: Screenings::Start/Complete) com os sinais dados.
  def care_screening!(unit:, citizen:, by:, vitals:)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    started = Screenings::Start.call(attendance: attendance, by: by).payload[:screening]
    result = Screenings::Complete.call(screening: started, revision_params: revision_params("vitals" => vitals), destination: "oriented",
                                       destination_params: { "orientation_note" => "retorno" }, by: by)
    raise "escuta recusada: #{result.reason}" if result.failure?

    started.reload
  end
end

RSpec.configure { |c| c.include CareLineHelpers }
