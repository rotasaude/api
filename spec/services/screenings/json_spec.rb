require "rails_helper"

# Contratos §3–§4: formas da escuta, da revisão, do item da fila do
# acolhimento e do bloco que a fila do profissional (e a recepção) recebe.
RSpec.describe Screenings::Json do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: 25.minutes.ago) }

  def complete!(destination: "same_day", params: {}, **revision)
    screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: screening, revision_params: revision_params(**revision), destination: destination,
                              destination_params: params, by: nurse)
    screening.reload
  end

  it "escuta concluída com a revisão corrente: chaves do contrato, números como número, opcionais só quando há" do
    acolhimento!
    screening = complete!(final_color: "red", complaint_note: "dor de cabeça forte",
                          vitals: { "systolic" => 185, "diastolic" => 110, "temperature_c" => "38,2",
                                    "weight_kg" => "80", "height_cm" => 175 })
    json = described_class.screening(screening).deep_stringify_keys
    expect(json.keys).to match_array(%w[id attendance_id status started_at completed_at destination current_revision revisions_count])
    expect(json.values_at("status", "destination", "revisions_count")).to eq([ "completed", "same_day", 1 ])
    revision = json["current_revision"]
    expect(revision.keys).to match_array(%w[id created_at by ciap2 complaint_note vitals alerts suggested_color final_color matched_rules])
    expect(revision["by"]).to eq("id" => nurse.id, "name" => nurse.professional.professional_name)
    expect(revision["ciap2"]).to eq("code" => "K86", "label" => "Hipertensão sem complicações")
    expect(revision["vitals"]).to eq("systolic" => 185, "diastolic" => 110, "temperature_c" => 38.2, "weight_kg" => 80.0,
                                     "height_cm" => 175, "bmi" => 26.1)
    expect(revision["alerts"]).to eq(%w[systolic_high diastolic_high temperature_high])
    expect(revision["matched_rules"]).to eq([ { "index" => 0, "text" => "pressão sistólica ≥ 180 ou saturação < 90" } ])
    expect(described_class.screening(screening, with_revisions: true)[:revisions].size).to eq(1)
  end

  it "oriented leva orientation_note; schedule leva appointment_request_id" do
    oriented = complete!(destination: "oriented", params: { "orientation_note" => "repouso" })
    expect(described_class.screening(oriented)).to include(orientation_note: "repouso")
    expect(described_class.screening(oriented)).not_to have_key(:appointment_request_id)
  end

  it "bloco da fila: cor, destino e espera em minutos; nada sem escuta concluída; sem queixa nem sinais" do
    freeze_time do
      expect(described_class.queue_block(attendance)).to be_nil
      complete!(final_color: "yellow")
      block = described_class.queue_block(attendance.reload)
      expect(block).to eq(id: attendance.screening.id, color: "yellow", destination: "same_day", waited_minutes: 25)
      expect(described_class.queue_block(attendance, now: Time.current + 9.minutes)[:waited_minutes]).to eq(34)
    end
  end

  it "bloco da fila: escuta em curso não tem bloco" do
    freeze_time do
      Screenings::Start.call(attendance: attendance, by: nurse)
      expect(described_class.queue_block(attendance.reload)).to be_nil
    end
  end

  it "item da fila do acolhimento" do
    Screenings::Start.call(attendance: attendance, by: nurse)
    item = described_class.queue_item(attendance.reload).deep_stringify_keys
    expect(item.keys).to match_array(%w[attendance_id citizen checked_in_at triage_priority screening])
    expect(item["citizen"]).to eq("id" => attendance.citizen_id, "cpf_masked" => attendance.citizen.cpf_masked)
    expect(item["screening"]).to include("status" => "in_progress", "started_by_name" => nurse.professional.professional_name)
  end

  # Única tradução índice → frase (reusada pelo suggest e pelo simulador).
  it "matched_rules_for: índice e frase da regra; regra ausente ou inválida não quebra" do
    rules = ScreeningHelpers::RULES
    expect(described_class.matched_rules_for([ 1, 2 ], rules)).to eq(
      [ { index: 1, text: "temperatura ≥ 39 ou glicemia ≥ 300" }, { index: 2, text: "queixa (CIAP-2) = R05" } ]
    )
    expect(described_class.matched_rules_for([], rules)).to eq([])
    expect(described_class.matched_rules_for([ 7 ], rules)).to eq([ { index: 7, text: "regra inválida" } ])
    expect(described_class.matched_rules_for([ 0 ], nil)).to eq([ { index: 0, text: "regra inválida" } ])
    expect(described_class.matched_rules_for([ 0 ], [ { "color" => "red" } ])).to eq([ { index: 0, text: "todos" } ])
  end

  it "staff_name: nome profissional; sem perfil, o e-mail; sem usuário, nil" do
    expect(described_class.staff_name(nurse)).to eq(nurse.professional.professional_name)
    expect(described_class.staff_name(reception!)).to eq(reception!.email_address)
    expect(described_class.staff_name(nil)).to be_nil
  end
end
