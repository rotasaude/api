# spec/invariants/triage_catalog_invariants_spec.rb
require "rails_helper"

# Invariantes do ADR 0027 (spec 2026-10-05 §9.2). Cada bloco diz a mutação que
# ele pega; rode a mutação à mão uma vez (Step 3) antes de confiar no verde.
RSpec.describe "Invariantes do catálogo de triagens (ADR 0027)" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:admin) { staff_with("inv-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }

  # 1. A restrição da cidade nunca amplia a elegibilidade assinada.
  # Mutação: em Triages::Offer.evaluate, trocar o E por OU entre elegibilidade
  # e restrição, ou pular a elegibilidade quando há linha.
  it "1. a restrição nunca amplia" do
    idoso = { name: "idoso", offer: { "eligibility" => { "gte" => ["profile.age", 60] } } }
    restrictions = [ nil, { "gte" => ["profile.age", 0] }, { "any" => [ { "gte" => ["profile.age", 0] }, { "eq" => ["profile.sex", "male"] } ] },
                     { "not" => { "lt" => ["profile.age", 0] } } ]
    (0..100).step(7).to_a.product(%w[female male]).each do |age, sex|
      context = Protocols::ConditionContext.build(profile: { age: age, sex: sex })
      signed = age >= 60 ? [ "idoso" ] : [] # o que a elegibilidade assinada permite
      restrictions.each do |restriction|
        row = Triages::Offer::Row.new(enabled: true, position: 1, restriction: restriction, available_from: nil, available_until: nil)
        with_row = Triages::Offer.evaluate(protocols: [ idoso ], rows: { "idoso" => row }, context: context,
                                           last_completed: {}, on: Date.new(2026, 10, 5)).map(&:protocol_name)
        expect(with_row - signed).to be_empty, "#{age}/#{sex}/#{restriction.inspect}"
      end
    end
  end

  # 2. Perfil verified não muda pelo canal do cidadão.
  # Mutação: tirar o `profile_verified` de Citizens::SetProfile, ou deixar
  # RegisterPerson sobrescrever o perfil de par existente.
  it "2. perfil verified não muda pelo canal do cidadão" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", birth_date: "1963-04-02", sex: "female",
                              profile_source: "verified")
    expect(Citizens::SetProfile.call(citizen: citizen, birth_date: "1990-01-01", sex: "male", gender_identity: nil).reason)
      .to eq(:profile_verified)
    Citizens::RegisterPerson.call(phone: citizen.phone, cpf: citizen.cpf,
                                  profile: { birth_date: "1990-01-01", sex: "male", gender_identity: nil })
    expect(citizen.reload).to have_attributes(birth_date: "1963-04-02", sex: "female", profile_source: "verified")
  end

  # 3. Nenhum payload de evento, URL ou log carrega data de nascimento, idade,
  # sexo ou identidade de gênero.
  # Mutação: pôr `sex:` ou `birth_date:` em qualquer DomainEvents.publish do
  # módulo; tirar :sex do filter_parameters; criar rota com o perfil no path.
  it "3. nenhum evento, rota ou log carrega o perfil" do
    active_protocol!("saude-mental-aprofundada")
    active_protocol!("saude-mental", suggestions: [ { "protocol" => "saude-mental-aprofundada", "when" => { "gte" => ["outcome.score", 4] } } ])
    reg = Citizens::RegisterPerson.call(phone: "+5541998765432", cpf: "52998224725",
                                        profile: { birth_date: "1963-04-02", sex: "female", gender_identity: "cis_woman" })
    citizen = reg.payload[:citizen]
    Citizens::SetProfile.call(citizen: citizen, birth_date: "1963-04-03", sex: "female", gender_identity: "travesti")
    started = start_for!(citizen, "saude-mental").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "true", idempotency_key: SecureRandom.uuid)
    Triages::SetOffer.call(protocol_name: "saude-mental", attributes: { "enabled" => true, "position" => 1,
                                                                         "restriction" => { "gte" => ["profile.age", 18] } }, by: admin)
    other = Citizen.create!(cpf: CampaignHistory.cpf_for("inv-verify"), phone: "+5541900000001")
    Citizens::Verify.call(cpf: other.cpf, code: issue_code_for(other), document_checked: true, by: admin,
                          birth_date: "1950-07-08", sex: "male")

    names = %w[citizen.profile_changed triage.suggested triage_offer.changed]
    expect(DomainEvent.where(name: names).distinct.pluck(:name)).to match_array(names)
    forbidden_keys = %w[birth_date sex gender_identity age profile]
    forbidden_values = [ "1963-04-02", "1963-04-03", "1950-07-08", "female", "male", "cis_woman", "travesti",
                         citizen.age.to_s ]
    DomainEvent.find_each do |event|
      keys = deep_keys(event.payload)
      expect(keys & forbidden_keys).to be_empty, "#{event.name}: #{keys.inspect}"
      values = deep_values(event.payload).map(&:to_s)
      expect(values & forbidden_values).to be_empty, "#{event.name}: #{values.inspect}"
    end

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter("birth_date" => "x", "sex" => "x", "gender_identity" => "x").values.uniq).to eq([ "[FILTERED]" ])

    # Segmento por segmento (e nome de parâmetro dinâmico), não substring: rotas
    # como /neighborhoods/:id/coverage ou /rails/active_storage/... não são perfil.
    profile_segments = %w[birth birthdate birth_date birthday sex gender gender_identity age idade sexo nascimento]
    offending = Rails.application.routes.routes.map { |r| r.path.spec.to_s }.select do |path|
      path.sub(/\(\.:format\)\z/, "").split("/").reject(&:empty?)
          .map { |segment| segment.delete_prefix(":").delete_prefix("*").downcase }
          .intersect?(profile_segments)
    end
    expect(offending).to be_empty
  end

  # 4. Resultado urgente nunca gera sugestão.
  # Mutação: tirar o `return [] if Protocols::Urgency.urgent?(outcome)`.
  it "4. urgente nunca sugere (e o mesmo resultado não urgente sugere)" do
    active_protocol!("saude-mental-aprofundada")
    # A regra é VERDADEIRA para a resposta gravada pelo completed_triage! (q1 = "false").
    active_protocol!("saude-mental", suggestions: [ { "protocol" => "saude-mental-aprofundada", "when" => { "eq" => ["q1", "false"] } } ])
    citizen = profiled_citizen!(age: 30)
    triage = completed_triage!(citizen, "saude-mental")

    urgent = Protocols::Outcome.terminal(trail: [], tier: "alta", priority: 1, score: 99)
    expect(Protocols::Urgency.urgent?(urgent)).to be(true)
    expect(Triages::Suggest.call(triage: triage, outcome: urgent)).to eq([])
    expect(TriageSuggestion.where(citizen: citizen).count).to eq(0)

    # Controle positivo: sem urgência, a mesma regra sugere.
    calm = Protocols::Outcome.terminal(trail: [], tier: "media", priority: 5, score: 4)
    expect(Protocols::Urgency.urgent?(calm)).to be(false)
    expect(Triages::Suggest.call(triage: triage, outcome: calm).map(&:protocol_name)).to eq([ "saude-mental-aprofundada" ])
  end

  # 5. Sugestão nunca aponta para o próprio protocolo.
  # Mutação: tirar o teste de nome igual do gate (Validation::Offer) ou do
  # Triages::Suggest.
  it "5. nunca sugere a si mesmo, nem pelo gate nem em execução" do
    definition = catalog_definition("saude-mental", suggestions: [ { "protocol" => "saude-mental", "when" => { "eq" => ["q1", "false"] } } ])
    expect(Protocols::Gate.call(definition).errors).to include("suggestions[0]: suggestion points to the protocol itself")

    # Gravado por fora do gate, com uma regra para si e outra (controle) para
    # outro protocolo, ambas verdadeiras para q1 = "false".
    active_protocol!("saude-mental-aprofundada")
    runtime = catalog_definition("saude-mental", suggestions: [
      { "protocol" => "saude-mental", "when" => { "eq" => ["q1", "false"] } },
      { "protocol" => "saude-mental-aprofundada", "when" => { "eq" => ["q1", "false"] } }
    ])
    ProtocolDefinition.create!(name: "saude-mental", version: 1, status: "active", definition: runtime)
    citizen = profiled_citizen!(age: 30)
    triage = completed_triage!(citizen, "saude-mental")
    outcome = Protocols::Outcome.terminal(trail: [], tier: "media", priority: 5, score: 4)
    expect(Triages::Offer.available?(citizen: citizen, protocol_name: "saude-mental")).to be(true)
    expect(Triages::Suggest.call(triage: triage, outcome: outcome).map(&:protocol_name)).to eq([ "saude-mental-aprofundada" ])
  end

  # 6. A triagem continua apontando a versão exata do protocolo usada (ADR 0010).
  # Mutação: StartTriage gravar a versão errada (ex.: a primeira, não a ativa).
  it "6. a triagem aponta a versão ativa exata" do
    ProtocolDefinition.create!(name: "saude-mental", version: 1, status: "retired", definition: catalog_definition("saude-mental"))
    v2 = active_protocol!("saude-mental", version: 2)
    # Versão mais nova que NÃO é a ativa: pega quem busca a primeira ou a última.
    ProtocolDefinition.create!(name: "saude-mental", version: 3, status: "published", definition: catalog_definition("saude-mental"))
    citizen = profiled_citizen!(age: 30)
    triage = start_for!(citizen, "saude-mental").payload[:triage]
    expect(triage.protocol_definition_id).to eq(v2.id)
  end

  def deep_keys(value)
    case value
    when Hash then value.keys.map(&:to_s) + value.values.flat_map { |v| deep_keys(v) }
    when Array then value.flat_map { |v| deep_keys(v) }
    else []
    end
  end

  def deep_values(value)
    case value
    when Hash then value.values.flat_map { |v| deep_values(v) }
    when Array then value.flat_map { |v| deep_values(v) }
    else [ value ]
    end
  end
end

# 7. Nenhum dado de perfil ou sugestão de um par aparece para outro par.
# Mutação: buscar o par por id sem o escopo da sessão em people#catalog/profile,
# ou devolver suggestions de triagem de outro par em triages#show.
RSpec.describe "Invariante 7 do ADR 0027: pares não se enxergam", type: :request do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
    active_protocol!("saude-mental-aprofundada")
    sign_in_citizen("+5541998765432")
  end
  after { Current.reset; Rails.cache.clear }

  it "perfil, catálogo e sugestões de outro par ficam fora da sessão" do
    mine = profiled_citizen!(age: 30, cpf: "52998224725")
    mine.update!(verification_level: "verified")
    other = profiled_citizen!(age: 62, cpf: "52998224725", phone: "+5541900000000")
    source = completed_triage!(other, StartTriage::DEFAULT_PROTOCOL_NAME)
    TriageSuggestion.create!(citizen: other, source_triage: source, protocol_name: "saude-mental-aprofundada")

    get "/citizen/people"
    expect(JSON.parse(response.body)["people"].map { |p| p["id"] }).to eq([ mine.id ])
    get "/citizen/people/#{other.id}/catalog"
    expect(response).to have_http_status(:not_found)
    json_post "/citizen/people/#{other.id}/profile", birth_date: "1990-01-01", sex: "male", gender_identity: nil
    expect(response).to have_http_status(:not_found)
    get "/citizen/people/#{mine.id}/catalog"
    expect(JSON.parse(response.body)["suggested"]).to eq([])
    get "/citizen/triages/#{source.id}"
    expect(JSON.parse(response.body)["suggestions"]).to eq([])
    expect(response.body).not_to include(other.birth_date)
  end
end
