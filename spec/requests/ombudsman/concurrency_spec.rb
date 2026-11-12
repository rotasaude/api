require "rails_helper"

# Review Focus 1 do plano do 33 (ADR 0051; contrato §2; §16 Q32; preflight
# F-19): duas técnicas agem na MESMA manifestação ao mesmo tempo — uma manda a
# resposta conclusiva, a outra encaminha — as duas com
# `expected_state: "in_analysis"`. Uma vence (200 com o detalhe); a outra
# espera a trava da manifestação (Ombudsman::Lock, FOR UPDATE), relê o estado
# novo e recebe 409 manifestation_changed — e nada dela é gravado: nem
# evento, nem encaminhamento, nem aviso ao cidadão, nem evento de domínio.
# Nas duas ordens.
#
# Threads reais contra TEST_CITY_A (sem fixture transacional) e a requisição
# de verdade, pela pilha inteira do Rails, numa ActionDispatch::Integration::Session
# por thread (o padrão de spec/requests/pharmacy/unit_deactivation_concurrency_spec.rb
# e do módulo 09: pop(timeout:), e o after solta as threads e apaga tudo o
# que commitou). Por isso NÃO é `type: :request`: o hook desse tipo grava a
# City no banco da plataforma e, sem fixture transacional, ela ficaria lá;
# aqui o catálogo de cidades é um stub que devolve TEST_CITY_A. A prova de que
# a segunda esperou vem de pg_stat_activity, nunca de sleep. A primeira fica
# parada logo depois de publicar o seu evento de domínio, antes do commit,
# segurando a trava.
RSpec.describe "Ouvidoria — conclusiva × encaminhamento na mesma manifestação" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:extract) { "Extrato do caso enviado enquanto a outra técnica respondia." }
  let(:answer) { "A coordenação da unidade revisou a escala e o caso foi resolvido." }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def user!(tag, role)
    User.create!(email_address: "#{role}-#{tag}@cidade.gov.br", password: "senha-segura-123").tap do |user|
      Membership.create!(user: user, role: role, granted_at: Time.current)
      (ids[:users] ||= []) << user.id
    end
  end

  def cookie_for(user_id)
    session = Session.create!(user_id: user_id, user_agent: "rspec", ip_address: "127.0.0.1")
    ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
  end

  before do
    served = TEST_CITY_A.dup.tap { |city| city.schema_version = CitySchema.expected_version.to_s }
    allow(CityCatalog).to receive(:find_by_host).and_return(served)
    allow(Ombudsman::Gate).to receive(:usable?).and_return(true)
    in_city do
      Ombudsman::Settings.ensure_defaults!
      tag = SecureRandom.hex(4)
      admin = user!(tag, "municipal_admin")
      ids[:answering] = user!("#{tag}-a", "ombudsman_staff").id
      ids[:forwarding] = user!("#{tag}-b", "ombudsman_staff").id
      responder = user!(tag, "ombudsman_responder")
      ids[:department] = Department.create!(name: "Setor Corrida #{tag}", updated_by_user: admin).id
      ids[:responder] = OmbudsmanResponder.create!(user: responder, department_id: ids[:department], created_by_user: admin).id
      ids[:citizen] = Citizen.create!(cpf: "52998224725", phone: "+5541990#{format('%06d', SecureRandom.random_number(1_000_000))}").id
      ids[:cookies] = { answering: cookie_for(ids[:answering]), forwarding: cookie_for(ids[:forwarding]) }
      now = Time.current
      ids[:manifestation] = OmbudsmanManifestation.create!(
        protocol: OmbudsmanManifestation.next_protocol(now), kind: "complaint", identification_mode: "identified", channel: "phone",
        created_by_user_id: ids[:answering], citizen_id: ids[:citizen], body: OmbudsmanHelpers::BODY, state: "in_analysis",
        received_at: now, cycle_started_on: now.in_time_zone.to_date
      ).id
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
        DomainEvent.where("payload->>'manifestation_id' = ?", ids[:manifestation].to_s).delete_all
        OmbudsmanNotice.where(ombudsman_manifestation_id: ids[:manifestation]).delete_all
        OmbudsmanEvent.where(ombudsman_manifestation_id: ids[:manifestation]).delete_all
        OmbudsmanForwarding.where(ombudsman_manifestation_id: ids[:manifestation]).delete_all
        OmbudsmanManifestation.where(id: ids[:manifestation]).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        OmbudsmanResponder.where(id: ids[:responder]).delete_all
        Department.where(id: ids[:department]).delete_all
        Session.where(user_id: ids[:users]).delete_all
        Membership.where(user_id: ids[:users]).delete_all
        User.where(id: ids[:users]).delete_all
      end
    end
  end

  # A requisição inteira, na thread de quem chama: [ status, corpo ] (ou a exceção).
  def post_action(user_key, action, params)
    http = ActionDispatch::Integration::Session.new(Rails.application)
    http.host! "#{TEST_CITY_A.slug}.rotasaude.app"
    http.cookies[:session_id] = ids[:cookies].fetch(user_key)
    http.post "/ombudsman/manifestations/#{ids[:manifestation]}/#{action}", params: params.to_json,
                                                                            headers: { "CONTENT_TYPE" => "application/json" }
    [ http.response.status, JSON.parse(http.response.body) ]
  rescue StandardError => e
    e
  end

  def final_response = post_action(:answering, "final_response", expected_state: "in_analysis", text: answer, resolution: "resolved")

  def forward
    post_action(:forwarding, "forward", expected_state: "in_analysis", department_id: ids[:department], extract: extract)
  end

  # A primeira grava, publica `event` e fica parada antes do commit; a
  # segunda tem de esperar na trava da manifestação.
  # -> [resposta da primeira, resposta da segunda]
  def race(event, first, second)
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == event
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_out = Queue.new
    threads << (holder = Thread.new { Thread.current.report_on_exception = false; first_out << first.call })
    holding.pop(timeout: 10) or raise "a primeira não chegou a gravar"

    second_out = Queue.new
    threads << other = Thread.new { Thread.current.report_on_exception = false; second_out << second.call }
    expect(wait_for_lock_wait).to be(true) # a segunda espera na trava da manifestação
    expect(other.join(0.3)).to be_nil

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    [ first_out.pop(timeout: 1), second_out.pop(timeout: 1) ]
  end

  def rows
    in_city do
      m = ids[:manifestation]
      { state: OmbudsmanManifestation.where(id: m).pick(:state),
        events: OmbudsmanEvent.where(ombudsman_manifestation_id: m).order(:created_at, :id).pluck(:kind, :actor_user_id),
        forwardings: OmbudsmanForwarding.where(ombudsman_manifestation_id: m).count,
        notices: OmbudsmanNotice.where(ombudsman_manifestation_id: m).pluck(:kind),
        domain: DomainEvent.where("payload->>'manifestation_id' = ?", m.to_s).order(:id).pluck(:name) }
    end
  end

  it "a conclusiva entra primeiro: 200 com o detalhe; o encaminhamento espera e recebe 409 manifestation_changed sem gravar nada" do
    (answered_status, answered), (forward_status, refused) = race("ombudsman.concluded", -> { final_response }, -> { forward })

    expect(answered_status).to eq(200)
    expect(answered).to include("id" => ids[:manifestation], "state" => "answered", "resolution" => "resolved")
    expect(answered.keys).to include("events", "forwardings", "can")
    expect([ forward_status, refused ]).to eq([ 409, { "error" => "manifestation_changed" } ])

    expect(rows).to eq(state: "answered", events: [ [ "final_response", ids[:answering] ] ], forwardings: 0,
                       notices: [ "final_response" ], domain: [ "ombudsman.concluded" ])
  end

  it "o encaminhamento entra primeiro: 200 com o detalhe; a conclusiva espera e recebe 409 sem evento, sem aviso e sem ombudsman.concluded" do
    (forward_status, forwarded), (answered_status, refused) = race("ombudsman.forwarded", -> { forward }, -> { final_response })

    expect(forward_status).to eq(200)
    expect(forwarded).to include("id" => ids[:manifestation], "state" => "forwarded", "pending_forwardings" => 1)
    expect(forwarded.keys).to include("events", "forwardings", "can")
    expect([ answered_status, refused ]).to eq([ 409, { "error" => "manifestation_changed" } ])

    expect(rows).to eq(state: "forwarded", events: [ [ "forwarded", ids[:forwarding] ] ], forwardings: 1,
                       notices: [], domain: [ "ombudsman.forwarded" ])
  end
end
