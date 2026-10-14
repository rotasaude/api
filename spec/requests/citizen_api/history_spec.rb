require "rails_helper"

# Contrato §4 (ADR 0035): o histórico do cidadão. Par validado vê a pessoa
# inteira (sem texto clínico livre); par declarado vê só triagens e
# agendamentos dele. Review Focus 3: a família no mesmo celular.
RSpec.describe "Histórico do cidadão", type: :request do
  before { timeline_city!(documents: true); ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit("UBS Centro") }
  let(:doctor) { doctor!(unit) }
  let(:mother) { verified_citizen!(111, social_name: "Dona Lu") }
  let!(:child) { Citizen.create!(cpf: "39053344705", phone: mother.phone, verification_level: "declared") }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: mother) }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  it "sem sessão: 401; interruptor desligado: 403 feature_disabled" do
    get "/citizen/history", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 401, "unauthenticated" ])
    sign_in_citizen(mother.phone)
    Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/history", params: { citizen_id: mother.id }
    expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "patient_timeline" ])
  end

  it "par validado: a pessoa inteira, documento com PDF e código, trilha citizen, sem texto livre" do
    document = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    other_phone_pair = Citizen.create!(cpf: mother.cpf, phone: "+5541988880001", verification_level: "verified",
                                       patient_id: consultation.patient_id)
    completed_web_triage_for(mother) # a da consulta já existe: com a do outro telefone, são três
    completed_web_triage_for(other_phone_pair)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(body.slice("verified", "partial")).to eq("verified" => true, "partial" => false)
    kinds = body["entries"].map { |e| e["kind"] }
    expect(kinds).to include("consultation", "clinical_document", "attendance", "triage")
    expect(kinds.count("triage")).to eq(3)
    doc = body["entries"].find { |e| e["kind"] == "clinical_document" }
    expect(doc["document"]).to eq("id" => document.id, "short_code" => document.short_code,
                                  "verification_url" => document.verification_url, "downloadable" => true)
    expect(body["entries"].first.keys).to include("professional_name")
    expect(body["entries"].first.keys).not_to include("detail_ref", "professional")
    expect(response.body).not_to include("Refere sede", "Metformina", "T90", "Diabetes")
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
      .to include("access" => "citizen", "user_id" => nil, "person_ref" => "patient:#{consultation.patient_id}")
  end

  it "família no mesmo celular: o declarado vê só triagens e agendamentos dele; de outro telefone, 404 (Review Focus 3)" do
    consultation
    completed_web_triage_for(child)
    stranger = verified_citizen!(112)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: child.id }
    expect(body["verified"]).to be(false)
    expect(body["entries"].map { |e| e["kind"] }.uniq).to eq(%w[triage])
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload["person_ref"]).to eq("citizen:#{child.id}")
    get "/citizen/history", params: { citizen_id: stranger.id }
    expect(status_and_error).to eq([ 404, "not_found" ])
    get "/citizen/history"
    expect(status_and_error).to eq([ 404, "not_found" ])
  end

  it "PDF: só documento da própria pessoa, não cancelado e baixável" do
    paper = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    unsigned = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "digital")
    strangers = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(113))
    foreign = raw_document!(consultation: strangers, kind: "sick_note", issue_mode: "paper")
    sign_in_citizen(mother.phone)
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to include("no-store")
    [ unsigned.id, foreign.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
      get "/citizen/documents/#{id}/pdf", params: { citizen_id: mother.id }
      expect(status_and_error).to eq([ 404, "not_found" ]), id
    end
    paper.update_columns(status: "cancelled", cancelled_at: Time.current, cancel_reason: "emitido por engano",
                         cancelled_by_user_id: doctor.id)
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 404, "not_found" ])
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: child.id }
    expect(status_and_error).to eq([ 403, "not_verified" ])
  end

  it "PDF: registro da Notificação e clinical_documents desligado dão 404; anexo; teto de 30 por 10 min dá 429" do
    paper = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    notification = raw_document!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper")
    sign_in_citizen(mother.phone)
    get "/citizen/documents/#{notification.id}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 404, "not_found" ])

    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to start_with("attachment")

    Platform::Features.set!(city: Current.city, key: "clinical_documents", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/citizen/documents/#{paper.id}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 404, "not_found" ])

    # O cache de teste é :null_store, que nunca conta; um real só aqui.
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    30.times { get "/citizen/documents/#{SecureRandom.uuid}/pdf", params: { citizen_id: mother.id } }
    expect(response).to have_http_status(:not_found)
    get "/citizen/documents/#{SecureRandom.uuid}/pdf", params: { citizen_id: mother.id }
    expect(status_and_error).to eq([ 429, "too_many_requests" ])
  end

  it "cursor e kinds inválidos: 422; kinds recorta só dentro do que a pessoa pode ver" do
    consultation
    completed_web_triage_for(child)
    sign_in_citizen(mother.phone)
    get "/citizen/history", params: { citizen_id: mother.id, before: "lixo" }
    expect(status_and_error).to eq([ 422, "invalid_cursor" ])
    get "/citizen/history", params: { citizen_id: mother.id, kinds: %w[nope] }
    expect(status_and_error).to eq([ 422, "invalid_kinds" ])
    get "/citizen/history", params: { citizen_id: mother.id, kinds: %w[consultation], limit: 1 }
    expect(body["entries"].map { |e| e["kind"] }).to eq(%w[consultation])
    get "/citizen/history", params: { citizen_id: child.id, kinds: %w[consultation triage] }
    expect(body["entries"].map { |e| e["kind"] }.uniq).to eq(%w[triage])
  end
end
