require "rails_helper"

# Módulo 31 (contrato §6, P14, P24, P37; plano, Desvio 7; ruling
# action_out_of_rule): as pendências do mês por registro, lidas e nunca
# gravadas. O profissional da ação precisa de CNS e de vínculo no retrato do
# CNES (CNES do CAPS, CBO da ação); a ação cancelada não conta; a ação fora da
# regra é relida só pela SIGTAP (instrumento, CBO, quantidade, autorização).
RSpec.describe Psychosocial::MonthProblems do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:month) { Date.new(2026, 11, 1) }
  let(:enrollment) { enrollment!(caps, started_on: month) }

  def report = described_class.for(health_unit: caps, month: month)
  def entry = report[:records].sole

  it "registro completo: sem problema nem aviso" do
    complete_month!(enrollment, month)
    expect(entry).to include(problems: [], warnings: [], actions_count: 1)
    expect(report[:counts]).to eq(records: 1, open: 1, closed: 0, exported: 0, with_problems: 0, with_warnings: 0, actions: 1)
  end

  it "profissional sem vínculo no retrato → professional_not_in_cnes; sem retrato nenhum → idem" do
    complete_month!(enrollment, month)
    loose = caps_staff!(caps)
    record_action!(caps, loose, participants: [ { enrollment_id: enrollment.id } ])
    expect(entry[:problems]).to eq(%w[professional_not_in_cnes])

    CnesSnapshot.delete_all
    expect(entry[:problems]).to eq(%w[professional_not_in_cnes])
  end

  it "vínculo no CNES de outra unidade ou com outro CBO não vale" do
    complete_month!(enrollment, month)
    other = caps_staff!(caps, cbo: "225133")
    bond = caps_cnes_bond!(other, caps)
    record_action!(caps, other, participants: [ { enrollment_id: enrollment.id } ])
    expect(entry[:problems]).to eq([])

    bond.update_columns(cbo_code: "251510")
    expect(entry[:problems]).to eq(%w[professional_not_in_cnes])
    bond.update_columns(cbo_code: "225133", cnes: billing_cnes)
    expect(entry[:problems]).to eq(%w[professional_not_in_cnes])
  end

  it "profissional sem CNS → professional_cns_missing" do
    staff = caps_staff!(caps)
    complete_month!(enrollment, month, by: staff)
    staff.professional.update_column(:cns, "")
    expect(entry[:problems]).to eq(%w[professional_cns_missing])
  end

  it "ação cancelada não conta: no_actions é aviso, não pendência" do
    record = complete_month!(enrollment, month)
    action = PsychosocialAction.sole
    action.update!(cancelled_at: Time.current, cancelled_by_user: action.professional_user, cancel_reason: "Lançada por engano")
    expect(entry).to include(problems: [], warnings: %w[no_actions], actions_count: 0)
    expect(entry[:record]).to eq(record)
  end

  # Fix round 1 da Task 10: o aviso olha só a ação RAAS (raas_psi), a única que
  # entra na remessa e nas fichas; a ação BPA-C conta em actions_count e na crítica.
  it "registro só com ação BPA-C → aviso no_actions, e o fechamento passa mesmo assim" do
    by = caps_staff!(caps, cbo: "223505", lead: true)
    caps_cnes_bond!(by, caps)
    record = Psychosocial::MonthlyRecords.ensure!(enrollment, month)
    record.update!(homeless: false)
    record_action!(caps, by, sigtap_code: "0301080305", participants: [ { enrollment_id: enrollment.id } ])
    expect(PsychosocialAction.sole.instrument).to eq("bpa_c")

    expect(entry).to include(problems: [], warnings: %w[no_actions], actions_count: 1)
    expect(report[:counts]).to include(with_warnings: 1, actions: 1)
    expect(Psychosocial::CloseMonth.call(unit: caps, month: month, by: by)).to be_ok
    expect(record.reload.status).to eq("closed")
  end

  it "ação que a SIGTAP de hoje recusa (CBO fora da lista) → action_out_of_rule" do
    complete_month!(enrollment, month)
    by = PsychosocialAction.sole.professional_user
    action = PsychosocialAction.create!(health_unit: caps, sigtap_code: "0301080208", instrument: "raas_psi", performed_at: 1.hour.ago,
                                        month: month, place: "caps", quantity: 1, professional_user: by, cbo_code: "999999", origin: "manual")
    PsychosocialActionParticipant.create!(psychosocial_action: action, position: 1, psychosocial_enrollment: enrollment,
                                          patient_id: enrollment.patient_id)
    expect(entry[:problems]).to eq(%w[professional_not_in_cnes action_out_of_rule])
  end

  it "paciente sem CNS nem telefone, situação de rua não informada" do
    patient = caps_patient!(cns: false)
    Citizen.find_by!(patient_id: patient.id).update!(phone: "123") # sem 10–11 dígitos: telefone que não serve
    enrollment!(caps, patient: patient, started_on: month)
    expect(entry[:problems]).to eq(%w[patient_cns_missing phone_missing homeless_missing])
  end

  it "só lê: nada gravado, nenhum evento" do
    enrollment
    expect { report }.not_to(change { [ PsychosocialMonthlyRecord.count, PsychosocialMonthlyRecord.where(status: "open").count, DomainEvent.count ] })
  end
end
