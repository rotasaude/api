require "rails_helper"

# Módulo 33, Task 18 (ADR 0051; ADR 0026; contrato §13 corrigido por §16 Q5 e
# Q46, Q56, Q57): a manifestação da ouvidoria não retém o pedido de exclusão
# (Q5). Na confirmação, o Citizens::Erase copia o nome de exibição (o social,
# quando houver — Q56), o CPF e o telefone do par para manifestant_name,
# manifestant_cpf e manifestant_phone (Q57; nunca para manifestant_contact, que
# é o contato digitado pela equipe) — só os que estão nulos: o nome declarado
# do par sem consentimento (U1/Q46) nunca é sobrescrito —, anula `citizen_id`,
# apaga os avisos da ouvidoria do par e mantém a pesquisa de satisfação. O
# detalhe mostra o telefone só mascarado; o número completo, só por
# POST …/identity, com trilha.
RSpec.describe "Exclusão LGPD com manifestação da ouvidoria (ADR 0051)", type: :request do
  let!(:city) { ombudsman_city! }
  let(:admin) { staff_with("gestor-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:phone) { "+5541998765432" }
  let(:citizen) { web_citizen!(phone: phone).tap { |c| c.update!(full_name: "Joana Exclusão Souza") } }

  after { Current.reset }

  # A cifra gravada, sem decifrar.
  def raw_manifestant(m)
    ApplicationRecord.connection.select_rows(
      ApplicationRecord.sanitize_sql([ "SELECT manifestant_name, manifestant_contact FROM ombudsman_manifestations WHERE id = ?", m.id ])
    ).first
  end

  # A linha inteira, como está gravada.
  def raw_row(m)
    ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ "SELECT * FROM ombudsman_manifestations WHERE id = ?", m.id ])
    ).to_a.sole
  end

  def open_identity(m)
    json_post "/ombudsman/manifestations/#{m.id}/identity", justification: "Retorno da ligação sobre o caso registrado."
  end

  def request!(cpf) = Citizens::RequestErasure.call(cpf: cpf, document_checked: true, by: verifier!)

  def erase!(cpf)
    request = request!(cpf).payload[:request]
    expect(request.status).to eq("pending") # a manifestação não retém (Q5)
    result = Citizens::Erase.call(request: request, by: admin)
    expect(result).to be_ok
    expect(result.payload[:request].status).to eq("confirmed")
  end

  it "cidadão só com manifestações: pendente; confirmada, os manifestant_* recebem a identidade, citizen_id nulo, sem aviso e a satisfação fica" do
    cpf = citizen.cpf
    identified = raw_manifestation!(citizen: citizen, state: "in_analysis")
    preserved = raw_manifestation!(citizen: citizen, identification_mode: "preserved", kind: "suggestion", state: "in_analysis")
    answered = raw_manifestation!(citizen: citizen, state: "answered", resolution: "resolved", concluded_at: Time.current)
    survey = OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: answered, met: "yes", clear: true, score: 5)
    OmbudsmanNotice.create!(citizen: citizen, ombudsman_manifestation: identified, kind: "interim_response", created_at: Time.current)
    OmbudsmanNotice.create!(citizen: citizen, ombudsman_manifestation: answered, kind: "final_response", created_at: Time.current)
    other = web_citizen!(phone: "+5541911112222")
    kept_notice = OmbudsmanNotice.create!(citizen: other, ombudsman_manifestation: raw_manifestation!(citizen: other),
                                          kind: "interim_response", created_at: Time.current)
    sign_in_citizen(phone)
    get "/citizen/ombudsman/manifestations"
    expect(json_body["manifestations"].map { |m| m["id"] }).to contain_exactly(identified.id, preserved.id, answered.id)

    erase!(cpf)

    [ identified, preserved, answered ].each do |m|
      expect(m.reload).to have_attributes(citizen_id: nil, manifestant_name: "Joana Exclusão Souza", manifestant_cpf: cpf,
                                          manifestant_phone: phone, manifestant_contact: nil)
    end
    expect(OmbudsmanNotice.where(citizen_id: citizen.id)).to be_empty
    expect(OmbudsmanNotice.where(id: kept_notice.id)).to exist
    expect(OmbudsmanSatisfactionResponse.where(id: survey.id, ombudsman_manifestation_id: answered.id)).to exist
    expect(citizen.reload).to have_attributes(full_name: nil, erased_at: be_present)
    expect(citizen.cpf).to start_with(Citizens::Erase::TOMBSTONE_PREFIX)

    # A sessão do cidadão foi apagada; uma sessão nova no mesmo telefone não acha nada.
    get "/citizen/ombudsman/manifestations"
    expect(response).to have_http_status(:unauthorized)
    sign_in_citizen(phone)
    get "/citizen/ombudsman/manifestations"
    expect(response).to have_http_status(:ok)
    expect(json_body["manifestations"]).to eq([])

    # Q57: o telefone sai mascarado, como antes da exclusão; o contato da
    # equipe (nenhum, aqui) fica nulo; o número completo não sai no detalhe.
    sign_in_as(ombudsman_staff!)
    get "/ombudsman/manifestations/#{identified.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["identity"]).to eq("name" => "Joana Exclusão Souza", "cpf_masked" => CitizenIdentity::Cpf.mask(cpf),
                                        "phone_masked" => CitizenIdentity::Phone.mask(phone), "contact" => nil)
    expect(response.body).not_to include(phone.delete_prefix("+55"), cpf)
    expect(json_body.dig("can", "open_identity")).to be(false) # o técnico nunca abre a identidade
    get "/ombudsman/manifestations/#{preserved.id}"
    expect(json_body).to include("identity" => "preserved", "identity_available" => true)
    expect(json_body.dig("can", "open_identity")).to be(false)
    expect(response.body).not_to include(cpf, "Joana", CitizenIdentity::Cpf.mask(cpf), CitizenIdentity::Phone.mask(phone))

    # O número completo só por /identity, e cada abertura deixa trilha. Sem o
    # cidadão, os manifestant_* copiados mantêm a identidade disponível: o
    # ouvidor segue podendo abrir (can.open_identity).
    sign_in_as(ombudsman!)
    [ identified, preserved ].each do |m|
      get "/ombudsman/manifestations/#{m.id}"
      expect(json_body.dig("can", "open_identity")).to be(true), m.identification_mode
      expect(json_body.dig("can", "record_identity_consent")).to be(true), m.identification_mode
    end
    expect { open_identity(identified) }.to change { OmbudsmanIdentityAccess.where(ombudsman_manifestation_id: identified.id).count }.by(1)
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("name" => "Joana Exclusão Souza", "full_name" => nil, "cpf" => nil, "phone" => phone,
                            "manifestant_name" => "Joana Exclusão Souza", "manifestant_contact" => nil, "manifestant_cpf" => cpf)
    expect { open_identity(preserved) }.to change { OmbudsmanIdentityAccess.where(ombudsman_manifestation_id: preserved.id).count }.by(1)
    expect(json_body).to include("phone" => phone, "manifestant_cpf" => cpf)
  end

  it "Q56: com nome social, manifestant_name recebe o nome social, não o civil; o CPF segue identificando a pessoa" do
    citizen.update!(social_name: "Renata Exclusão")
    m = raw_manifestation!(citizen: citizen, state: "in_analysis")
    cpf = citizen.cpf

    erase!(cpf)

    expect(m.reload).to have_attributes(citizen_id: nil, manifestant_name: "Renata Exclusão", manifestant_cpf: cpf, manifestant_phone: phone,
                                        manifestant_contact: nil)
    sign_in_as(ombudsman_staff!)
    get "/ombudsman/manifestations/#{m.id}"
    expect(json_body["identity"]).to include("name" => "Renata Exclusão")
    expect(response.body).not_to include("Joana")
  end

  it "um CPF com dois pares (dois telefones): cada manifestação recebe o telefone do seu par" do
    cpf = citizen.cpf
    second_phone = "+5541955554444"
    second = web_citizen!(cpf: cpf, phone: second_phone)
    first_m = raw_manifestation!(citizen: citizen)
    second_m = raw_manifestation!(citizen: second, identification_mode: "preserved", kind: "suggestion")

    erase!(cpf)

    expect(first_m.reload).to have_attributes(citizen_id: nil, manifestant_cpf: cpf, manifestant_phone: phone, manifestant_contact: nil)
    expect(second_m.reload).to have_attributes(citizen_id: nil, manifestant_cpf: cpf, manifestant_phone: second_phone,
                                               manifestant_name: nil, manifestant_contact: nil)
  end

  it "anônima e registro da equipe sem cidadão (com o CPF excluído no manifestant_cpf) ficam intocados" do
    cpf = citizen.cpf
    raw_manifestation!(citizen: citizen)
    anonymous = raw_manifestation!(kind: "report", identification_mode: "anonymous")
    by_staff = raw_manifestation!(channel: "phone", manifestant_name: "Joana Exclusão Souza", manifestant_cpf: cpf,
                                  manifestant_contact: "(41) 3333-4444")
    before = [ raw_row(anonymous), raw_row(by_staff) ]

    erase!(cpf)

    expect([ raw_row(anonymous), raw_row(by_staff) ]).to eq(before)
    expect(by_staff.reload).to have_attributes(citizen_id: nil, manifestant_phone: nil, manifestant_contact: "(41) 3333-4444")
  end

  it "par declarado sem consentimento (U1/Q46): o nome declarado fica, CPF e telefone vêm do par, e o par sem consentimento se exclui" do
    declared_phone = "+5541977776666"
    sign_in_citizen(declared_phone)
    json_post "/citizen/ombudsman/manifestations", cpf: "111.444.777-35", full_name: "Maria Declarada", kind: "complaint",
                                                   identification_mode: "identified", body: "Esperei quatro horas na recepção da UBS sem atendimento."
    expect(response).to have_http_status(:created)
    manifestation = OmbudsmanManifestation.find(json_body["id"])
    pair = manifestation.citizen
    expect(pair).to have_attributes(full_name: nil, cpf: "11144477735", phone: declared_phone)
    expect(manifestation.manifestant_name).to eq("Maria Declarada")
    expect(Consent.count).to eq(0)

    erase!("11144477735")

    expect(manifestation.reload).to have_attributes(citizen_id: nil, manifestant_name: "Maria Declarada",
                                                    manifestant_cpf: "11144477735", manifestant_phone: declared_phone,
                                                    manifestant_contact: nil)
    expect(pair.reload.erased_at).to be_present
  end

  it "manifestant_* já preenchido nunca é reescrito (o trigger compara a cifra)" do
    m = raw_manifestation!(citizen: citizen, manifestant_name: "Nome Declarado", manifestant_contact: "(41) 3333-4444")
    before_cipher = raw_manifestant(m)
    cpf = citizen.cpf

    erase!(cpf)

    expect(m.reload).to have_attributes(citizen_id: nil, manifestant_name: "Nome Declarado", manifestant_contact: "(41) 3333-4444",
                                        manifestant_cpf: cpf, manifestant_phone: phone)
    expect(raw_manifestant(m)).to eq(before_cipher)
  end

  it "RequestErasure.retained? não conta a manifestação (Q5)" do
    raw_manifestation!(citizen: citizen)
    expect(Citizens::RequestErasure.retained?(Citizens::RequestErasure.pairs_of(citizen.cpf), cpf: citizen.cpf)).to be(false)
  end
end

# Review Focus 3: a exclusão chega enquanto a equipe manda uma resposta
# intermediária (Ombudsman::InterimResponse trava cidadão FOR KEY SHARE →
# manifestação FOR UPDATE e grava o aviso; o Erase trava o par FOR UPDATE →
# manifestação FOR UPDATE). A mesma ordem nos dois caminhos: nada de
# deadlock, e o aviso ou foi apagado pela exclusão ou não nasceu. Threads reais
# contra TEST_CITY_A (padrão do módulo 09: pop(timeout:), limpeza no after);
# não é `type: :request` (o hook desse tipo gravaria a City na plataforma).
RSpec.describe Citizens::Erase, "concorrência com a resposta intermediária da ouvidoria" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:text) { "Estamos apurando o caso com a coordenação da unidade." }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  before do
    in_city do
      ids[:started_at] = Time.current
      tag = SecureRandom.hex(4)
      ids[:admin] = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:verifier] = User.create!(email_address: "ver-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:staff] = User.create!(email_address: "ouv-#{tag}@c.gov.br", password: "senha-segura-123").id
      cpf = CampaignHistory.cpf_for("ombudsman-#{tag}")
      ids[:cpf] = cpf
      ids[:phone] = "+55419#{format('%08d', 70_000_000 + SecureRandom.random_number(1_000_000))}"
      citizen = Citizen.create!(cpf: cpf, phone: ids[:phone], full_name: "Ana Corrida Lima")
      ids[:citizen] = citizen.id
      now = Time.current
      base = { kind: "complaint", channel: "web", citizen_id: citizen.id, body: OmbudsmanHelpers::BODY, received_at: now,
               cycle_started_on: now.in_time_zone.to_date }
      ids[:manifestation] = OmbudsmanManifestation.create!(base.merge(protocol: OmbudsmanManifestation.next_protocol(now),
                                                                      identification_mode: "preserved", state: "in_analysis")).id
      ids[:answered] = OmbudsmanManifestation.create!(base.merge(protocol: OmbudsmanManifestation.next_protocol(now),
                                                                 identification_mode: "identified", state: "answered",
                                                                 resolution: "resolved", concluded_at: now)).id
      ids[:survey] = OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation_id: ids[:answered], met: "partly", clear: true,
                                                           score: 4).id
      ids[:erasure] = CitizenErasureRequest.create!(cpf: cpf, presented_citizen: citizen, requested_by_user_id: ids[:verifier],
                                                    document_checked: true, status: "pending").id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError, ScriptError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        manifestation_ids = ids.values_at(:manifestation, :answered).compact
        DomainEvent.where(created_at: ids[:started_at]..).delete_all if ids[:started_at]
        OmbudsmanNotice.where(ombudsman_manifestation_id: manifestation_ids).delete_all
        OmbudsmanSatisfactionResponse.where(ombudsman_manifestation_id: manifestation_ids).delete_all
        OmbudsmanEvent.where(ombudsman_manifestation_id: manifestation_ids).delete_all
        OmbudsmanManifestation.where(id: manifestation_ids).delete_all
        CitizenErasureRequest.where(id: ids[:erasure]).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        User.where(id: ids.values_at(:admin, :verifier, :staff).compact).delete_all
      end
    end
  end

  # Exceção (ex.: ActiveRecord::Deadlocked) vira o valor devolvido.
  def capture
    yield
  rescue StandardError => e
    e
  end

  def erase
    capture do
      in_city { described_class.call(request: CitizenErasureRequest.find(ids[:erasure]), by: User.find(ids[:admin])) }
    end
  end

  def interim
    capture do
      in_city do
        Ombudsman::InterimResponse.call(manifestation_id: ids[:manifestation], expected_state: "in_analysis", text: text,
                                        by: User.find(ids[:staff]))
      end
    end
  end

  # Segura `holder` dentro de `method` de `mod` (travas já pegas, antes da escrita).
  def hold(mod, method, holding, holder_ref)
    allow(mod).to receive(method).and_wrap_original do |original, *args, **kwargs|
      if Thread.current == holder_ref.call
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      original.call(*args, **kwargs)
    end
  end

  def race(first, second)
    holding = Queue.new
    holder = nil
    yield(holding, -> { holder })

    first_out = Queue.new
    threads << (holder = Thread.new { Thread.current.report_on_exception = false; first_out << first.call })
    holding.pop(timeout: 10) or raise "a primeira não chegou às travas"

    second_out = Queue.new
    threads << other = Thread.new { Thread.current.report_on_exception = false; second_out << second.call }
    expect(in_city { wait_for_lock_wait }).to be(true)
    expect(other.join(0.3)).to be_nil

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    [ first_out.pop(timeout: 1), second_out.pop(timeout: 1) ]
  end

  def expect_erased_state
    in_city do
      [ ids[:manifestation], ids[:answered] ].each do |id|
        expect(OmbudsmanManifestation.find(id)).to have_attributes(citizen_id: nil, manifestant_name: "Ana Corrida Lima",
                                                                   manifestant_cpf: ids[:cpf], manifestant_phone: ids[:phone],
                                                                   manifestant_contact: nil)
      end
      expect(OmbudsmanNotice.where(citizen_id: ids[:citizen])).to be_empty
      expect(OmbudsmanSatisfactionResponse.where(id: ids[:survey])).to exist
      expect(Ombudsman::Json.identity(OmbudsmanManifestation.find(ids[:manifestation]))).to eq("preserved")
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: ids[:manifestation], kind: "interim_response").count).to eq(1)
    end
  end

  it "resposta intermediária já com as travas, exclusão chega: sem deadlock; o aviso nasce e a exclusão o apaga" do
    interimed, erased = race(-> { interim }, -> { erase }) do |holding, holder|
      hold(Ombudsman::Notify, :call, holding, holder)
    end

    expect(interimed).to be_a(Result).and be_ok
    expect(erased).to be_a(Result).and be_ok
    expect(in_city { CitizenErasureRequest.find(ids[:erasure]).status }).to eq("confirmed")
    expect_erased_state
  end

  it "exclusão já com as travas, resposta intermediária chega: espera, relê citizen_id nulo e o aviso não nasce" do
    erased, interimed = race(-> { erase }, -> { interim }) do |holding, holder|
      hold(described_class, :erase_pair, holding, holder)
    end

    expect(erased).to be_a(Result).and be_ok
    expect(interimed).to be_a(Result).and be_ok
    expect(in_city { OmbudsmanNotice.where(ombudsman_manifestation_id: ids[:manifestation]).count }).to eq(0)
    expect_erased_state
  end
end
