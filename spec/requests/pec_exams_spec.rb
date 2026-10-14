require "rails_helper"

# Spec §6 "Botão no PEC" (Divergência D8): o botão na página do PEC leva o
# token da sessão curta num formulário; nasce o pedido com origem pec, o
# profissional e o paciente da chamada; sem cookie; CSP form-action 'self'.
RSpec.describe "Solicitar exames pelo PEC", type: :request do
  let(:unit) { create_unit("UBS Norte").tap { |u| u.update!(cnes: "1234567") } }
  let(:nurse) { screener!(unit).tap { |u| u.professional.update!(cpf: "52998224725") } }
  let(:citizen) { verified_citizen!(exam_seq!, social_name: "Seu Zé") }

  before do
    timeline_city!(record_mode: "integrated", clinical_record: false, pec: true)
    pec_settings!
    %w[exam_tracking exam_pec_bridge].each do |key|
      Platform::Features.set!(city: Current.city, key: key, enabled: true, maintainer: ledi_maintainer!)
    end
    sigtap_release!
    exam_catalog_item!
    nurse
    walk_in_attendance!(unit, citizen: citizen)
  end

  def open_page = get(signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567"))
  def token_in(body) = body[/name="token" value="([^"]+)"/, 1].then { |v| CGI.unescapeHTML(v.to_s) }

  it "a página traz o botão; o formulário lista o catálogo; o pedido nasce com origem pec" do
    open_page
    expect(response.body).to include("Solicitar exames")
    expect(response.headers["Content-Security-Policy"]).to include("form-action 'self'")
    token = token_in(response.body)
    post "/pec/exams/form", params: { token: token }
    expect(response.body).to include("DOSAGEM DE HEMOGLOBINA GLICOSILADA", "Seu Zé")
    expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors https://pec.cidade.gov.br", "form-action 'self'")
    expect(response.headers).not_to have_key("Set-Cookie")
    post "/pec/exams", params: { token: token, sigtap_code: "0202010503", priority: "urgent" }
    order = ExamOrder.last
    expect(order).to have_attributes(origin: "pec", priority: "urgent", requester_user_id: nurse.id, unit_id: unit.id,
                                     patient_id: citizen.reload.patient_id)
    expect(response.body).to include("Pedido registrado", order.short_code)
    expect(response.body).not_to include(citizen.cpf)
    # Evento só com ids (leitura determinística).
    expect(DomainEvent.where(name: "exam_order.requested").order(:id).last.payload)
      .to eq("exam_order_id" => order.id, "origin" => "pec", "priority" => "urgent")
  end

  it "sem token, interruptor desligado e exame fora do catálogo" do
    post "/pec/exams/form", params: { token: "lixo" }
    expect([ response.status, response.body ]).to match([ 401, a_string_including("pec_session_expired") ])
    open_page
    token = token_in(response.body)
    post "/pec/exams", params: { token: token, sigtap_code: "0202020380", priority: "routine" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("sigtap_not_in_catalog")
    post "/pec/exams", params: { token: token, sigtap_code: "0202010503", priority: "whenever" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("invalid_priority")
    expect(ExamOrder.count).to eq(0)
    # Tudo numa transação: a recusa do catálogo desfaz o paciente criado pelo Resolve.
    expect(citizen.reload.patient_id).to be_nil
    Platform::Features.set!(city: Current.city, key: "exam_pec_bridge", enabled: false, maintainer: ledi_maintainer!)
    post "/pec/exams/form", params: { token: token }
    expect([ response.status, response.body ]).to match([ 403, a_string_including("pec_exam_bridge_disabled") ])
    get signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567", at: 2.seconds.ago) # URL nova (uso único)
    expect(response.body).to include("Linha do tempo")
    expect(response.body).not_to include("Solicitar exames")
    expect(response.headers["Content-Security-Policy"]).to include("form-action 'none'")
  end

  it "o token não vai para a URL nem para o log; o formulário escapa o nome" do
    citizen.update!(social_name: "<b>Zé</b>")
    open_page
    token = token_in(response.body)
    expect(response.body).not_to include("token=")
    logged = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)
    begin
      post "/pec/exams/form", params: { token: token }
    ensure
      Rails.logger = original
    end
    expect(response.body).to include("&lt;b&gt;Zé&lt;/b&gt;")
    expect(response.body).not_to include("<b>Zé</b>")
    expect(logged.string).not_to include(token)
  end

  it "envio repetido na janela da sessão curta não duplica; outro exame na mesma janela nasce" do
    exam_catalog_item!(sigtap_code: "0202020380")
    open_page
    token = token_in(response.body)
    body = { token: token, sigtap_code: "0202010503", priority: "routine" }
    post "/pec/exams", params: body
    first = ExamOrder.sole
    post "/pec/exams", params: body
    expect(response).to have_http_status(:ok)
    expect(ExamOrder.count).to eq(1)
    expect(response.body).to include("Este exame já foi registrado (guia #{first.short_code})")
    expect(response.body).not_to include("Pedido registrado")
    post "/pec/exams", params: body.merge(sigtap_code: "0202020380")
    expect(response.body).to include("Pedido registrado")
    expect(ExamOrder.count).to eq(2)
  end

  it "limite por IP nas rotas novas: 429 too_many_requests" do
    open_page
    token = token_in(response.body)
    allow(PecTimelinesController::RateLimitStore).to receive(:increment).and_return(121)
    post "/pec/exams/form", params: { token: token }
    expect([ response.status, response.body ]).to match([ 429, a_string_including("too_many_requests") ])
    post "/pec/exams", params: { token: token, sigtap_code: "0202010503", priority: "routine" }
    expect([ response.status, response.body ]).to match([ 429, a_string_including("too_many_requests") ])
    expect(ExamOrder.count).to eq(0)
  end
end
