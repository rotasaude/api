require "rails_helper"

# Contrato §3: o JSON do atendimento e da consulta ganha `procedures`
# (forma resumida) só com procedure_billing ligado. E8: no atendimento, só
# para profissional ou leitor de faturamento (recepção não recebe a chave).
RSpec.describe "Procedimentos no atendimento e na consulta" do
  before { billing_city! }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:pair) { exam_patient!(exam_seq!) }

  def act_as(user) = Current.session = Struct.new(:user).new(user)

  def attendance_json(attendance) = AttendancesController.new.send(:attendance_json, attendance)

  it "a consulta e o atendimento listam os procedimentos dela/dele" do
    act_as doctor
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: pair.last)
    procedure = Billing::Record.call(patient: pair.first, establishment: Billing::Establishment.for_unit(unit), professional: doctor,
                                     source: "consultation", consultation: consultation, cbo_code: consultation.cbo_code, recorded_by: doctor,
                                     params: { "performed_on" => Time.zone.today.iso8601, "sigtap_code" => "0301060029", "quantity" => 1,
                                               "cid10" => "I10" }).payload[:procedure]
    summary = { id: procedure.id, sigtap_code: "0301060029", label: "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA",
                quantity: 1, performed_on: Time.zone.today.iso8601, billable: true, blocking_reasons: [], status: "recorded" }
    expect(Consultations::Json.consultation(consultation)[:procedures]).to eq([ summary ])
    walk_in = walk_in_attendance!(unit, citizen: pair.last)
    Billing::Record.call(patient: pair.first, establishment: Billing::Establishment.for_unit(unit), professional: doctor, source: "attendance",
                         attendance: walk_in, recorded_by: doctor,
                         params: { "performed_on" => Time.zone.today.iso8601, "sigtap_code" => "0301100012", "quantity" => 2 })
    expect(attendance_json(walk_in)[:procedures].map { |p| p[:sigtap_code] }).to eq(%w[0301100012])

    act_as billing_clerk!
    expect(attendance_json(walk_in)).to have_key(:procedures)

    act_as verifier!
    expect(attendance_json(walk_in)).not_to have_key(:procedures)

    act_as doctor
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    expect(Consultations::Json.consultation(consultation)).not_to have_key(:procedures)
    expect(attendance_json(walk_in)).not_to have_key(:procedures)
  end
end
