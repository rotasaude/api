require "rails_helper"

# Módulo 25, Task 9 (ADR 0043; contrato §4): a rede de segurança. Só item
# `add` dispara: na finalização, os da consulta; no adendo, os daquele adendo.
RSpec.describe Surveillance::SafetyNet do
  before { surveillance_city! }
  let(:unit) { HealthUnit.create!(name: "UBS Rede #{SecureRandom.hex(2)}", kind: "ubs") }
  let(:doctor) { doctor!(unit) }
  let(:dengue_add) { [ { "terminology" => "cid10", "code" => "A90", "action" => "add" } ] }

  def finalized!(n, problems)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(n), "evaluated_problems" => problems)
  end

  def addendum!(consultation, reason, problems)
    result = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: reason, text: "Texto do adendo.",
                                             changes: { "evaluated_problems" => problems })
    raise "adendo recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload[:addendum]
  end

  it "finalizada com A90 add e sem notificação vira possible; redespacho não duplica" do
    c = finalized!(51, dengue_add)
    expect(described_class.call(consultation: c)).to eq(created: 1)
    expect(described_class.call(consultation: c)).to eq(created: 0)
    n = DiseaseNotification.find_by!(consultation_id: c.id)
    expect([ n.status, n.origin, n.notifier_user_id, n.disease_code, n.addendum_id ]).to eq([ "possible", "safety_net", nil, "dengue", nil ])
    expect(n.health_unit_id).to eq(c.attendance.health_unit_id)
    expect(n.due_at).to be_within(1.second).of(c.finalized_at + 7.days)
    expect(n.events.pluck(:status, :by_user_id)).to eq([ [ "possible", nil ] ])
  end

  it "notificada na consulta não gera possible" do
    c = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(53))
    saved = Consultations::SaveDraft.call(consultation: c, params: draft_body("evaluated_problems" => dengue_add), by: doctor)
    raise "rascunho recusado: #{saved.reason}" if saved.failure?

    notified = Surveillance::NotifyFromConsultation.call(consultation: c.reload, disease_code: "dengue", symptoms_on: nil, by: doctor)
    expect(notified).to be_ok
    finalized = Consultations::Finalize.call(consultation: c.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
    expect(finalized).to be_ok

    expect(described_class.call(consultation: c.reload)).to eq(created: 0)
    expect(DiseaseNotification.where(patient_id: c.patient_id).pluck(:origin, :status)).to eq([ %w[consultation notified] ])
  end

  it "adendo que acrescenta gera (uma vez, mesmo redespachado); adendo que só reavalia não" do
    c = finalized!(52, [ { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
    expect(described_class.call(consultation: c)).to eq(created: 0)

    added = addendum!(c, "Resultado do exame chegou", dengue_add)
    expect(described_class.call(consultation: c, addendum: added)).to eq(created: 1)
    expect(described_class.call(consultation: c, addendum: added)).to eq(created: 0)
    possible = DiseaseNotification.sole
    expect([ possible.status, possible.addendum_id ]).to eq([ "possible", added.id ])
    expect(possible.due_at).to be_within(1.second).of(added.created_at + 7.days)

    # Dispensada, a possible deixa de bloquear: só o `evaluate` disparando criaria outra.
    possible.update!(status: "dismissed", dismissed_at: Time.current)
    again = addendum!(c, "Reavaliação do quadro", [ { "terminology" => "cid10", "code" => "A90", "action" => "evaluate",
                                                      "problem_id" => PatientProblem.find_by!(code: "A90").id } ])
    expect(described_class.call(consultation: c, addendum: again)).to eq(created: 0)
    # A finalização relida não traz os itens dos adendos.
    expect(described_class.call(consultation: c)).to eq(created: 0)
    expect(DiseaseNotification.count).to eq(1)
  end

  it "duas doenças casadas: uma possible por doença, sem repetir a mesma doença" do
    c = finalized!(54, [ { "terminology" => "cid10", "code" => "A90", "action" => "add" },
                         { "terminology" => "cid10", "code" => "A920", "action" => "add" } ])
    expect(described_class.call(consultation: c)).to eq(created: 2)
    expect(DiseaseNotification.where(consultation_id: c.id).pluck(:status).uniq).to eq([ "possible" ])
  end

  it "adendo de outra consulta é recusado" do
    c = finalized!(55, dengue_add)
    other = finalized!(56, [ { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
    foreign = addendum!(other, "Resultado do exame chegou", dengue_add)
    expect { described_class.call(consultation: c, addendum: foreign) }.to raise_error(ArgumentError)
  end
end
