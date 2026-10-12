require "rails_helper"

# Spec §7 (ADR 0035): HTML só leitura para a tela de "sistemas externos";
# frame-ancestors do PEC da cidade, sem X-Frame-Options; recusa genérica com
# código; uso único; sessão curta; CPF/CNS mascarados no log.
RSpec.describe "Página do PEC", type: :request do
  let(:unit) { create_unit("UBS Norte").tap { |u| u.update!(cnes: "1234567") } }
  let(:nurse) { screener!(unit).tap { |u| u.professional.update!(cpf: "52998224725") } }
  let(:citizen) { verified_citizen!(151, social_name: "Seu Zé") }

  before do
    timeline_city!(record_mode: "integrated", clinical_record: false, pec: true)
    pec_settings!
    nurse
    walk_in_attendance!(unit, citizen: citizen)
  end

  def open_page(**opts) = get(signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567", **opts))

  it "válida: HTML com aviso, a pessoa e as entradas; cabeçalhos de iframe; trilha pec_external" do
    open_page
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("Registros do Rota Saúde — consultas desta cidade estão no PEC.", "Seu Zé",
                                     "Atendimento — UBS Norte", "Triagem — ")
    expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors https://pec.cidade.gov.br")
    expect(response.headers).not_to have_key("X-Frame-Options")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    expect(response.body).not_to include(citizen.cpf, "52998224725")
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to include("access" => "pec_external", "user_id" => nurse.id, "person_ref" => "citizen:#{citizen.id}")
  end

  it "reenviada, vencida, inválida e sem vínculo: página genérica com o código, 403, sem dizer o parâmetro" do
    path = signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567")
    get path
    get path
    expect([ response.status, response.body ]).to match([ 403, a_string_including("pec_replayed") ])
    open_page(at: 10.minutes.ago)
    expect(response.body).to include("pec_expired")
    get path.sub(/pec_sign=\h{4}/, "pec_sign=0000")
    expect(response.body).to include("pec_signature_invalid")
    expect(response.body).not_to include("documento", "assinatura inválida", "timestamp")
    get signed_pec_path(professional: "11144477735", citizen: citizen.cpf, cnes: "1234567")
    expect(response.body).to include("pec_professional_not_linked")
    expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors https://pec.cidade.gov.br")
    expect(response.headers).not_to have_key("X-Frame-Options")
  end

  it "interruptor desligado: pec_disabled; sem configuração, frame-ancestors 'none'" do
    PecSetting.current.update!(pec_origin: nil)
    open_page
    expect(response.body).to include("pec_disabled")
    expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors 'none'")
  end

  it "carregar mais com a sessão curta; sem token, vínculo encerrado ou interruptor desligado: 401 (Review Focus 5)" do
    stub_const("PecTimelinesController::PAGE_LIMIT", 1)
    open_page
    token = response.body[/data-session="([^"]+)"/, 1]
    before = response.body[/data-before="([^"]+)"/, 1]
    expect([ token, before ]).to all(be_present)
    get "/pec/timeline/more", params: { before: before }, headers: { "X-Pec-View-Session" => CGI.unescapeHTML(token) }
    expect(response).to have_http_status(:ok)
    expect(response.body).to start_with("<li")
    expect(response.headers).to have_key("X-Next-Before")
    get "/pec/timeline/more", params: { before: before }
    expect([ response.status, response.body ]).to match([ 401, a_string_including("pec_session_expired") ])
    nurse.professional.links.active.sole.update!(ended_at: Time.current, ended_by_user: reception!)
    get "/pec/timeline/more", params: { before: before }, headers: { "X-Pec-View-Session" => CGI.unescapeHTML(token) }
    expect(response).to have_http_status(:unauthorized)
  end

  it "CPF, CNS e assinatura mascarados no log de requisições" do
    log = capture_log { open_page }
    expect(log).to include("/pec/timeline")
    expect(log).not_to include(citizen.cpf, "52998224725")
    expect(log).to include("[FILTERED]")
  end

  it "carregar mais relê os pares: o par excluído pela LGPD depois da abertura sai; sozinho, dá 401 pec_session_expired" do
    stub_const("PecTimelinesController::PAGE_LIMIT", 1)
    open_page
    token = CGI.unescapeHTML(response.body[/data-session="([^"]+)"/, 1])
    before = response.body[/data-before="([^"]+)"/, 1]
    headers = { "X-Pec-View-Session" => token }
    get "/pec/timeline/more", params: { before: before }, headers: headers
    expect(response).to have_http_status(:ok)

    citizen.update_columns(erased_at: Time.current)
    get "/pec/timeline/more", params: { before: before }, headers: headers
    expect([ response.status, response.body ]).to match([ 401, a_string_including("pec_session_expired") ])
  end

  it "carregar mais com dois pares validados: o excluído deixa de trazer as entradas dele; o outro continua" do
    south = create_unit("UBS Sul")
    twin = verified_citizen!(152, social_name: "Seu Zé")
    twin.update_columns(cpf: citizen.cpf)
    walk_in_attendance!(south, citizen: twin)
    stub_const("PecTimelinesController::PAGE_LIMIT", 1)
    open_page
    token = CGI.unescapeHTML(response.body[/data-session="([^"]+)"/, 1])
    before = response.body[/data-before="([^"]+)"/, 1]
    get "/pec/timeline/more", params: { before: before }, headers: { "X-Pec-View-Session" => token }
    expect(response).to have_http_status(:ok)

    twin.update_columns(erased_at: Time.current)
    get "/pec/timeline/more", params: { before: before }, headers: { "X-Pec-View-Session" => token }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("UBS Sul")
  end
end
