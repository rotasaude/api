require "rails_helper"

# Spec §7 (ADR 0035): HTML só leitura para a tela de "sistemas externos";
# frame-ancestors do PEC da cidade, sem X-Frame-Options; recusa genérica com
# código; uso único; sessão curta; CPF/CNS mascarados no log.
RSpec.describe "Página do PEC", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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

  it "carregar mais com o interruptor desligado depois da abertura: 401 pec_session_expired" do
    stub_const("PecTimelinesController::PAGE_LIMIT", 1)
    open_page
    headers = { "X-Pec-View-Session" => CGI.unescapeHTML(response.body[/data-session="([^"]+)"/, 1]) }
    before = response.body[/data-before="([^"]+)"/, 1]
    get "/pec/timeline/more", params: { before: before }, headers: headers
    expect(response).to have_http_status(:ok)

    Platform::Features.set!(city: Current.city, key: "pec_external_view", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/pec/timeline/more", params: { before: before }, headers: headers
    expect([ response.status, response.body ]).to match([ 401, a_string_including("pec_session_expired") ])
  end

  it "carregar mais: cursor inválido 422; última página com X-Next-Before vazio; fragmento com no-store e frame-ancestors" do
    open_page
    headers = { "X-Pec-View-Session" => CGI.unescapeHTML(response.body[/data-session="([^"]+)"/, 1]) }
    get "/pec/timeline/more", params: { before: "lixo" }, headers: headers
    expect([ response.status, response.body ]).to match([ 422, a_string_including("invalid_cursor") ])
    cursor = Timeline::Cursor.encode(Timeline::Query.call(person: Timeline::Person.for_cpf(citizen.cpf), limit: 1).entries.last)
    get "/pec/timeline/more", params: { before: cursor }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Next-Before"]).to eq("")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Content-Security-Policy"]).to include("frame-ancestors https://pec.cidade.gov.br")
  end

  it "origem gravada direto no banco com ';': a CSP cai para frame-ancestors 'none'" do
    PecSetting.current.update_columns(pec_origin: "https://pec.cidade.gov.br;script-src")
    open_page
    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("frame-ancestors 'none'")
    expect(csp).not_to include("pec.cidade.gov.br;script-src")
  end

  it "CPF, CNS e assinatura mascarados no log de requisições" do
    log = capture_log { open_page }
    expect(log).to include("/pec/timeline")
    expect(log).not_to include(citizen.cpf, "52998224725")
    expect(log).to include("[FILTERED]")
  end

  it "CNS em documento-cidadao e o valor de pec_sign também ficam fora do log" do
    path = signed_pec_path(professional: "52998224725", citizen: "898001160660001", cnes: "1234567")
    sign = path[/pec_sign=(\h+)/, 1]
    log = capture_log { get path }
    expect(log).not_to include("898001160660001", sign)
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
    travel_to(2.hours.ago) { walk_in_attendance!(south, citizen: twin) }
    stub_const("PecTimelinesController::PAGE_LIMIT", 1)
    open_page
    token = CGI.unescapeHTML(response.body[/data-session="([^"]+)"/, 1])
    before = response.body[/data-before="([^"]+)"/, 1]
    stub_const("PecTimelinesController::PAGE_LIMIT", 50)
    get "/pec/timeline/more", params: { before: before }, headers: { "X-Pec-View-Session" => token }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("UBS Sul") # controle positivo: o par ainda vale

    twin.update_columns(erased_at: Time.current)
    get "/pec/timeline/more", params: { before: before }, headers: { "X-Pec-View-Session" => token }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("UBS Sul")
  end

  it "rate limit por IP: show 120/min vira a página de recusa 429 too_many_requests, sem pec.external_view_denied" do
    # O cache de teste é :null_store, que nunca conta; um real só aqui.
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    120.times { get "/pec/timeline" }
    expect(response).to have_http_status(:forbidden)
    denied = DomainEvent.where(name: "pec.external_view_denied").count
    get "/pec/timeline"
    expect([ response.status, response.media_type ]).to eq([ 429, "text/html" ])
    expect(response.body).to include("too_many_requests")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers).not_to have_key("X-Frame-Options")
    expect(DomainEvent.where(name: "pec.external_view_denied").count).to eq(denied)
  end

  it "rate limit por IP: carregar mais 300/min vira 429 too_many_requests" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    300.times { get "/pec/timeline/more" }
    expect(response).to have_http_status(:unauthorized)
    get "/pec/timeline/more"
    expect([ response.status, response.body ]).to match([ 429, a_string_including("too_many_requests") ])
  end

end
