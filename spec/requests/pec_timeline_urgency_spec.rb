require "rails_helper"

# Página do PEC externo com a urgência (ADR 0050; contrato §14 Q27): a visita
# à UPA entra na forma do profissional (data, unidade, cor, CID e desfecho),
# com as linhas do BPA da urgência e os documentos do walk_in; o registro por
# engano e o paciente provisório ficam fora. A urgência segue fora do LEDI.
RSpec.describe "Página do PEC com a urgência", type: :request do
  include ActiveJob::TestHelper

  let!(:city) { urgency_city!(billing: true) }
  let(:upa) { upa!(name: "UPA Pinheirinho").tap { |u| u.update!(cnes: "7654321") } }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa).tap { |u| u.professional.update!(cpf: "52998224725") } }
  let(:patient) { urgency_patient!(41) }

  before do
    timeline_city!(documents: true, pec: true)
    pec_settings!
    ciap2_release!; cid10_release!; sigtap_release!
  end

  def open_page = get(signed_pec_path(professional: "52998224725", citizen: patient.cpf, cnes: "7654321"))

  def classified_and_finalized!(encounter)
    classified!(encounter, color: "orange", by: nurse, pain_scale: 9)
    called!(encounter, by: doctor)
    finalized_urgency!(encounter, doctor: doctor, cid10: "I10")
    encounter.reload
  end

  it "o encontro fechado aparece com cor, CID e desfecho, com o BPA e o documento do walk_in; o registro por engano e o provisório, não" do
    shown = classified_and_finalized!(arrived!(upa, patient: patient))
    Urgency::RecordOutcome.call(encounter: shown, attrs: { "kind" => "discharged" }, by: doctor)
    perform_enqueued_jobs(only: Billing::UrgencyProductionJob)
    expect(PerformedProcedure.where(urgency_encounter_id: shown.id).count).to eq(2)
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{shown.attendance_id}/declarations", content: {}, health_unit_id: upa.id
    expect(response).to have_http_status(:created)

    error = arrived!(upa, patient: patient)
    Urgency::RecordOutcome.call(encounter: error, attrs: { "kind" => "registered_in_error", "reason" => "Chegada lançada no paciente errado" },
                                by: upa_reception!)
    provisional = classified_and_finalized!(arrived!(upa, unidentified: "Mulher, 70 anos"))

    # A página do PEC exige o modo integrado (Timeline::Gate.pec_usable?) e um
    # par validado do CPF (PecExternal::Authorize): o encontro foi montado no
    # modo record e a cidade passa ao integrado só para abrir a página.
    Citizen.create!(cpf: patient.cpf, phone: "+5541988887041", verification_level: "verified", patient_id: patient.id)
    timeline_city!(record_mode: "integrated", clinical_record: false, documents: true, pec: true)
    open_page
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Atendimento de urgência — UPA Pinheirinho",
                                     "Laranja · I10 Hipertensão essencial (primária) · Alta", "Declaração de comparecimento")
    expect(response.body.scan("Atendimento de urgência — UPA Pinheirinho").size).to eq(1)
    expect(response.body.scan("UPA Pinheirinho").size).to be >= 4 # urgência, documento e as duas linhas do BPA
    expect(response.body).not_to include("Registrado por engano", "paciente errado", UrgencyHelpers::COMPLAINT)

    kinds = PecTimelinesController::KINDS
    expect(kinds).to include("urgency", "procedure", "clinical_document")
    pec = Timeline::Query.call(person: Timeline::Person.for_patient(patient), kinds: kinds, pec_view: true).entries
    expect(pec.select { |e| e.kind == "urgency" }.map(&:source_id)).to eq([ shown.id ])
    expect(Timeline::Query.call(person: Timeline::Person.for_patient(provisional.patient), kinds: %w[urgency], pec_view: true).entries)
      .to be_empty
    # O profissional do Rota Saúde segue vendo os dois.
    expect(Timeline::Query.call(person: Timeline::Person.for_patient(patient), kinds: %w[urgency]).entries.map(&:source_id))
      .to contain_exactly(shown.id, error.id)
    expect(Timeline::Query.call(person: Timeline::Person.for_patient(provisional.patient), kinds: %w[urgency]).entries.map(&:source_id))
      .to eq([ provisional.id ])
  end

  it "32b: a página do PEC mostra 'observação 6 h' no resumo (HTML), e o cidadão não" do
    shown = classified_and_finalized!(arrived!(upa, patient: patient))
    bed = urgency_bed!(upa)
    stay = observed!(shown, bed: bed, now: Time.current - 7.hours)
    stay.update!(ended_at: stay.started_at + 6.hours + 20.minutes, end_kind: "outcome", ended_by_user: doctor)
    Urgency::RecordOutcome.call(encounter: shown.reload, attrs: { "kind" => "discharged" }, by: doctor)
    Citizen.create!(cpf: patient.cpf, phone: "+5541988887041", verification_level: "verified", patient_id: patient.id)
    timeline_city!(record_mode: "integrated", clinical_record: false, documents: true, pec: true)
    open_page
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("observação 6 h")
    citizen = Timeline::Query.call(person: Timeline::Person.for_patient(patient), kinds: %w[urgency], citizen_view: true).entries
    expect(citizen.filter_map { |e| Timeline::Json.citizen(e) }.to_s).not_to include("observação", "observation_hours")
  end
end
