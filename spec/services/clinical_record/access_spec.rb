require "rails_helper"

# ADR 0031 (spec §5): em contexto, abertura justificada ou nada. A recepção
# nunca lê.
RSpec.describe ClinicalRecord::Access do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = clinical_city!; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:patient) { Patients::Resolve.call(citizen).payload[:patient] }

  def access(user, attendance: nil) = described_class.call(user: user, patient: patient, attendance: attendance)

  it "in_care chamado pelo usuário: em contexto; outro profissional: fora" do
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    expect(access(doctor).kind).to eq(:in_context)
    expect(access(doctor, attendance: attendance).kind).to eq(:in_context)
    expect(access(doctor!(unit, cbo: "223505")).then { |g| [ g.kind, g.reason ] }).to eq([ :denied, :out_of_context ])
  end

  it "waiting: quem tem vínculo permitido na unidade lê; técnico e outra unidade não" do
    walk_in_attendance!(unit, citizen: citizen)
    expect(access(doctor!(unit, cbo: "223505")).kind).to eq(:in_context)
    expect(access(doctor!(unit, cbo: "322205")).kind).to eq(:denied)
    expect(access(doctor!(create_unit("UBS Outra"))).kind).to eq(:denied)
  end

  it "atendimento fechado não é contexto; atendimento de outro CPF também não" do
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    other = consulting_attendance!(unit, citizen: verified_citizen!(2), doctor: doctor)
    expect(access(doctor, attendance: other).kind).to eq(:denied)
    attendance.update!(status: "closed", outcome: "discharged", closed_by_user: doctor, closed_at: Time.current)
    expect(access(doctor).kind).to eq(:denied)
  end

  it "abertura válida do próprio usuário: justificada, por 30 minutos" do
    nurse = doctor!(unit, cbo: "223505")
    now = Time.current
    opening = ClinicalRecordOpening.create!(patient: patient, user: nurse, reason_code: "case_review", created_at: now,
                                            expires_at: now + 30.minutes)
    grant = access(nurse)
    expect([ grant.kind, grant.opening ]).to eq([ :justified, opening ])
    expect(access(doctor).kind).to eq(:denied)
    travel_to(now + 30.minutes, with_usec: true) { expect(access(nurse).kind).to eq(:denied) }
  end

  it "par só declarado do mesmo CPF não dá contexto (Review Focus 5)" do
    patient # o paciente existe pelo par validado
    declared = profiled_citizen!(age: 41, cpf: citizen.cpf, phone: "+5541990001234")
    walk_in_attendance!(unit, citizen: declared)
    expect(access(doctor).then { |g| [ g.kind, g.reason ] }).to eq([ :denied, :out_of_context ])
  end

  it "sem paciente, atendimento de par só declarado nunca é contexto" do
    declared = screening_citizen!(4)
    attendance = in_care!(walk_in_attendance!(unit, citizen: declared), by: doctor)
    grant = described_class.call(user: doctor, patient: nil, attendance: attendance)
    expect([ grant.kind, grant.reason ]).to eq([ :denied, :out_of_context ])
  end

  it "abertura de outro paciente não justifica" do
    other = Patients::Resolve.call(verified_citizen!(2)).payload[:patient]
    ClinicalRecordOpening.create!(patient: other, user: doctor, reason_code: "case_review", created_at: Time.current,
                                  expires_at: 30.minutes.from_now)
    expect(access(doctor).kind).to eq(:denied)
  end

  # Decisão do usuário (2026-10-09): a autora da consulta FINALIZADA lê sem
  # atendimento aberto e sem abertura; o resto cai no Access.call de hoje.
  it "for_consultation: autora de finalizada → :author sem contexto; não autora fora de contexto; rascunho como hoje" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, exam_requests: [])
    expect(Attendance.open_attendances.where(id: consultation.attendance_id)).to be_empty
    grant = described_class.for_consultation(user: doctor, consultation: consultation)
    expect([ grant.kind, grant.opening, grant.reason, grant.allowed? ]).to eq([ :author, nil, nil, true ])
    nurse = doctor!(unit, cbo: "223505")
    expect(described_class.for_consultation(user: nurse, consultation: consultation).then { |g| [ g.kind, g.reason ] })
      .to eq([ :denied, :out_of_context ])
    expect(described_class.for_consultation(user: reception!, consultation: consultation).then { |g| [ g.kind, g.reason ] })
      .to eq([ :denied, :missing_role ])
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect(described_class.for_consultation(user: doctor, consultation: draft).kind).to eq(:in_context)
    expect(described_class.for_consultation(user: nurse, consultation: draft).kind).to eq(:denied)
  end

  it "recepção e papel ausente: missing_role" do
    expect(access(reception!).then { |g| [ g.kind, g.reason ] }).to eq([ :denied, :missing_role ])
  end
end
