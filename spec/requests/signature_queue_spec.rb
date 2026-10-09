# spec/requests/signature_queue_spec.rb
require "rails_helper"

# Contrato §5 (spec §5, lote e volta ao papel; NGS2.02.05/06): a fila do
# próprio autor, o lote com UMA aprovação (multi_signature, os dois hashes de
# cada documento numa chamada) e a volta ao papel com motivo.
RSpec.describe "Pendentes, lote e volta ao papel", type: :request do
  before do
    signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
    stub_psc!
    stub_signer!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  def body = JSON.parse(response.body)

  def pending_for!(user, n, at: unit, first_citizen: 10)
    Array.new(n) do |i|
      consultation = finalized_consultation!(unit: at, doctor: user, citizen: verified_citizen!(first_citizen + i))
      signature_request!(consultation, author: user, reason_code: "no_session")
    end
  end

  def other_professional!
    other_unit = create_unit("UBS Dois")
    [ signer_doctor!(other_unit, cpf: SignatureHelpers::OTHER_CPF), other_unit ]
  end

  def run_batch!(params = {})
    post "/signature/batches", params: { return_to: "/pendentes" }.merge(params), as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    post "/signature/oauth/callback", params: { state: state, code: authorize_and_approve!(url) }, as: :json
    url
  end

  it "lista só os pendentes do autor, mais antigos primeiro, na forma do contrato" do
    linked_certificate!(doctor)
    first, second = pending_for!(doctor, 2)
    other, other_unit = other_professional!
    pending_for!(other, 1, at: other_unit, first_citizen: 60)
    signature_request!(author: doctor, status: "signed")
    sign_in_as(doctor)
    get "/signature/requests", params: { status: "pending" }
    expect(body["items"].map { |i| i["id"] }).to eq([ first.id, second.id ])
    item = body["items"].first
    consultation = Consultation.find(first.document_id)
    expect(item).to eq("id" => first.id, "document_type" => "consultation", "document_id" => consultation.id,
                       "consultation_id" => consultation.id, "patient_display_name" => consultation.patient.display_name,
                       "finalized_at" => consultation.finalized_at.iso8601, "status" => "pending",
                       "reason_code" => "no_session", "attempts" => 0)
    # Contrato §13: lista sempre as pendentes, qualquer que seja o filtro pedido.
    get "/signature/requests", params: { status: "signed" }
    expect(body["items"].map { |i| i["id"] }).to eq([ first.id, second.id ])
  end

  it "volta ao papel: motivo de 10+, só o autor, só pendente; a nota nunca no log" do
    request = pending_for!(doctor, 1).first
    sign_in_as(doctor)
    post "/signature/requests/#{request.id}/return_to_paper", params: { reason: "curto" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_reason" ])
    sign_in_as(signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF))
    post "/signature/requests/#{request.id}/return_to_paper", params: { reason: "sem certificado hoje" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 403, "not_author" ])
    sign_in_as(doctor)
    log = capture_log do
      post "/signature/requests/#{request.id}/return_to_paper", params: { reason: "  sem   certificado hoje  " }, as: :json
    end
    expect(response).to have_http_status(:ok)
    expect(body).to include("id" => request.id, "status" => "returned_to_paper", "reason_code" => "user_request")
    expect(request.reload.return_note).to eq("sem certificado hoje")
    expect(log).not_to include("certificado hoje")
    stored = SignatureRequest.connection.select_value("SELECT return_note FROM signature_requests WHERE id = '#{request.id}'")
    expect(stored).not_to include("certificado") # cifrada com a chave da cidade
    post "/signature/requests/#{request.id}/return_to_paper", params: { reason: "sem certificado hoje" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "not_pending" ])
    post "/signature/requests/#{SecureRandom.uuid}/return_to_paper", params: { reason: "sem certificado hoje" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
    post "/signature/requests/lixo/return_to_paper", params: { reason: "sem certificado hoje" }, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "lote: uma aprovação multi_signature assina todos (dois hashes por documento numa chamada)" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    requests = pending_for!(doctor, 2)
    sign_in_as(doctor)
    url = run_batch!
    expect(URI.decode_www_form(URI(url).query).to_h).to include("scope" => "multi_signature", "login_hint" => cpf)
    expect(body).to eq("purpose" => "batch", "result" => { "signed" => 2, "failed" => [] }, "return_to" => "/pendentes")
    expect(requests.map { |r| r.reload.status }).to eq(%w[signed signed])
    expect(requests.map { |r| r.reload.signature.present? }).to eq([ true, true ])
    expect(fake_psc.log.count { |_verb, path| path == "/v0/oauth/signature" }).to eq(1)
  end

  it "lote: ids escolhidos; ids de outro autor e lixo ficam de fora; sem nada: 409; sem certificado: 409" do
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "certificate_not_linked" ])
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    post "/signature/batches", params: { return_to: "/" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "nothing_pending" ])
    mine = pending_for!(doctor, 2)
    other, other_unit = other_professional!
    theirs = pending_for!(other, 1, at: other_unit, first_citizen: 60)
    post "/signature/batches", params: { request_ids: [ mine.first.id, theirs.first.id, "lixo" ], return_to: "/" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body["count"]).to eq(1)
    expect(SignatureOauthState.where(purpose: "batch").order(:created_at).last.request_ids).to eq([ mine.first.id ])
  end

  it "profissional sem CPF: 409 professional_cpf_missing" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    pending_for!(doctor, 1)
    doctor.professional.update_columns(cpf: nil)
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "professional_cpf_missing" ])
  end

  context "com o interruptor signature_psc_mock ligado" do
    before { stub_psc_mock! }

    it "certificado vidaas (PSC real) não começa lote: 422 invalid_provider" do
      linked_certificate!(doctor, provider: "vidaas", leaf: fake_psc("simulated").leaf(cpf))
      signature_request!(author: doctor)
      sign_in_as(doctor)
      post "/signature/batches", params: { return_to: "/" }, as: :json
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_provider" ])
    end
  end

  it "lote com o PSC fora do ar na assinatura: itens em failed, pedidos continuam pendentes com o motivo" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    requests = pending_for!(doctor, 2)
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    code = authorize_and_approve!(url)
    # a troca do código passa; a assinatura cai
    allow_any_instance_of(Signatures::Psc::Client).to receive(:sign).and_raise(Signatures::Psc::Unavailable, "fora")
    post "/signature/oauth/callback", params: { state: state, code: code }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body["result"]).to eq("signed" => 0,
                                 "failed" => requests.map { |r| { "request_id" => r.id, "reason_code" => "provider_unavailable" } })
    expect(requests.map { |r| r.reload.slice(:status, :reason_code).values }).to all(eq(%w[pending provider_unavailable]))
    expect(Signature.count).to eq(0)
  end

  it "lote com a troca do código falhando: 503 provider_unavailable e nada muda" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    requests = pending_for!(doctor, 1)
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    code = authorize_and_approve!(url)
    allow_any_instance_of(Signatures::Psc::Client).to receive(:exchange).and_raise(Signatures::Psc::Unavailable, "fora")
    post "/signature/oauth/callback", params: { state: state, code: code }, as: :json
    expect([ response.status, body["error"], body["return_to"] ]).to eq([ 503, "provider_unavailable", "/" ])
    expect(requests.first.reload.slice(:status, :reason_code).values).to eq(%w[pending no_session])
  end

  it "token do lote sem o escopo multi_signature: 403 authorization_denied e nada assinado" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    requests = pending_for!(doctor, 1)
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    code = authorize_and_approve!(url)
    allow_any_instance_of(Signatures::Psc::Client).to receive(:exchange)
      .and_return(Signatures::Psc::Token.new(access_token: "t", expires_in: 300, scope: "signature_session"))
    post "/signature/oauth/callback", params: { state: state, code: code }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 403, "authorization_denied" ])
    expect(requests.first.reload.status).to eq("pending")
  end

  it "certificado re-vinculado a outro PSC entre o início e a volta: 403 authorization_denied, nenhum PSC é chamado" do
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    requests = pending_for!(doctor, 1)
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    code = authorize_and_approve!(url)
    certificate.update_columns(provider: "birdid") # re-vínculo: o token foi trocado com o vidaas
    expect(Signatures::Signing).not_to receive(:call)
    expect_any_instance_of(Signatures::Psc::Client).not_to receive(:sign)
    post "/signature/oauth/callback", params: { state: state, code: code }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 403, "authorization_denied" ])
    expect(requests.first.reload.slice(:status, :reason_code, :attempts).values).to eq([ "pending", "no_session", requests.first.attempts ])
    expect(Signature.count).to eq(0)
  end

  it "o lote pega no máximo 50" do
    linked_certificate!(doctor)
    51.times { signature_request!(author: doctor) }
    sign_in_as(doctor)
    post "/signature/batches", params: { return_to: "/" }, as: :json
    expect(body["count"]).to eq(50)
  end
end
