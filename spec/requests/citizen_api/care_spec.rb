require "rails_helper"

# Contrato §7 e §12 P5a/L9: "Meu acompanhamento" — só linhas inscritas,
# linguagem simples, sem código nem motivo, sem item não rastreado; triagem
# periódica vencida sempre (o módulo 15 não tem interruptor).
RSpec.describe "Cidadão — meu acompanhamento", type: :request do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }

  it "linhas inscritas com o que está para fazer; sugestão e não rastreado não aparecem; trilha citizen" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    citizen = Citizen.find_by!(patient_id: patient.id)
    care_enrollment!(patient: patient, line: adopted_line!("diabetes_c4"), team: team, by: doctor)
    CareLineSuggestion.create!(care_line: adopted_line!("hypertension_c5"), team: team, patient: patient, reason: "problem")
    active_protocol!("saude-adulto", offer: { "title" => "Saúde do adulto", "retake_after_days" => 180 })
    completed_triage!(citizen, "saude-adulto", at: 200.days.ago)
    sign_in_citizen(citizen.phone)
    get "/citizen/care", params: { citizen_id: citizen.id }
    expect(json_body["lines"].map { |l| l["name"] }).to eq([ "Pessoa com diabetes" ])
    items = json_body["lines"].first["items"]
    expect(items.map { |i| [ i["label"], i["status"] ] }).to eq([
      [ "Consulta de acompanhamento", "ok" ], [ "Medir a pressão", "ok" ], [ "Medir peso e altura", "ok" ],
      [ "Exame de hemoglobina glicada", "overdue" ], [ "Avaliação dos pés", "overdue" ]
    ])
    expect(items.map(&:keys).uniq).to eq([ %w[label status due_on] ])
    expect(response.body).not_to match(/T90|c4_|resolved_problem|hipertens|untracked/i)
    expect(json_body["overdue_triages"]).to eq([ { "protocol_name" => "saude-adulto", "title" => "Saúde do adulto",
                                                   "last_done_at" => 200.days.ago.to_date.iso8601 } ])
    views = DomainEvent.where(name: "clinical_record.viewed")
    expect(views.count).to eq(1)
    expect(views.last.payload).to include("access" => "citizen", "patient_id" => patient.id)
  end

  it "par validado sem paciente: sem linhas; par declarado: 403; outro celular: 404; desligado: 403" do
    citizen = care_citizen!(age: 30, sex: "female")
    sign_in_citizen(citizen.phone)
    get "/citizen/care", params: { citizen_id: citizen.id }
    expect(json_body).to eq("lines" => [], "overdue_triages" => [])
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(0)
    declared = profiled_citizen!(age: 30, phone: "+5541990000124")
    sign_in_citizen(declared.phone)
    get "/citizen/care", params: { citizen_id: declared.id }
    expect(json_body).to eq("error" => "not_verified")
    get "/citizen/care", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:not_found)
    Platform::Features.set!(city: Current.city, key: "care_lines", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/care", params: { citizen_id: declared.id }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "care_lines")
  end

  # Só anuncia o que o cidadão consegue começar (mesmo critério do catálogo).
  it "triagem vencida: só por sugestão sem sugestão pendente e a em andamento ficam fora" do
    citizen = care_citizen!(age: 40, sex: "female")
    %w[periodica so-sugestao em-andamento].each do |name|
      active_protocol!(name, offer: { "title" => name, "retake_after_days" => 180 })
      completed_triage!(citizen, name, at: 200.days.ago)
    end
    TriageOffer.create!(protocol_name: "so-sugestao", suggestion_only: true, updated_by_user: care_admin!)
    start_for!(citizen, "em-andamento")
    sign_in_citizen(citizen.phone)
    get "/citizen/care", params: { citizen_id: citizen.id }
    expect(json_body["overdue_triages"].map { |t| t["protocol_name"] }).to eq(%w[periodica])
    TriageSuggestion.create!(citizen: citizen, source_triage: completed_triage!(citizen, "em-andamento", at: 2.days.ago), protocol_name: "so-sugestao")
    get "/citizen/care", params: { citizen_id: citizen.id }
    expect(json_body["overdue_triages"].map { |t| t["protocol_name"] }).to contain_exactly("periodica", "so-sugestao")
  end
end
