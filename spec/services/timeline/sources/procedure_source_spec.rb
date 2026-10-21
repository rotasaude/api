require "rails_helper"

# Contrato §9 (F-22.7; fecha api#71 para procedimentos): o profissional vê
# nome, data, unidade e profissional; o cidadão vê nome, data e unidade, sem
# crítica nem faturamento; cancelado não aparece; vazio sem procedure_billing
# ou sem paciente; janela e cursor como os outros fornecedores.
RSpec.describe Timeline::Sources::ProcedureSource do
  include ActiveSupport::Testing::TimeHelpers

  before do
    billing_city!
    Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
  end

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:patient) { billing_patient! }
  let(:person) { Timeline::Person.for_patient(patient) }

  def entries(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)

  it "profissional e cidadão, do mais novo ao mais antigo, sem crítica nem faturamento" do
    older = travel_to(2.days.ago) { recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil) }
    newer = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    list = entries
    expect(list.map(&:source_id)).to eq([ newer.id, older.id ])
    expect(list.first).to have_attributes(kind: "procedure", status: "recorded", unit: { id: unit.id, name: unit.name },
                                          professional: { name: doctor.professional.professional_name, cbo_code: "225125" },
                                          title: "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA",
                                          detail_ref: { type: "performed_procedure", id: newer.id }, document: nil)
    citizen = Timeline::Json.citizen(list.last)
    expect(citizen).to include(kind: "procedure", title: "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA",
                               status: "recorded", status_label: "Realizado", professional_name: nil, unit: { name: unit.name })
    expect(citizen.keys).not_to include(:blocking_reasons, :billable, :instrument, :cid10)
    expect(list.map { |e| [ e.to_h, Timeline::Json.citizen(e) ] }.to_s).not_to include("cid_required", "billable", "bpa_")
  end

  it "cancelado some; desligado ou sem paciente, vazio" do
    procedure = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    Billing::Cancel.call(procedure: procedure, reason: "Lançado em duplicidade", by: doctor)
    expect(entries).to eq([])
    recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    expect(described_class.entries(person: Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: true), before: nil, limit: 10,
                                   from: nil, to: nil)).to eq([])
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    expect(entries).to eq([])
  end

  it "entra na consulta da linha do tempo e no laboratório mostra o laboratório como unidade" do
    lab = lab_provider!
    recorded_procedure!(unit: lab, professional: doctor, patient: patient, sigtap_code: "0202010473", cid10: nil)
    page = Timeline::Query.call(person: person, kinds: %w[procedure])
    expect(page.entries.sole.unit).to eq(id: lab.id, name: lab.name)
    expect(Timeline::KINDS.last).to eq("procedure")
  end
end
