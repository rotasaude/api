require "rails_helper"

# Spec §7 (ADR 0035): interruptor; assinatura; horário; uso único; CNES de
# unidade ativa; profissional com vínculo ativo nessa unidade; pessoa com par
# validado. Cada recusa publica pec.external_view_denied só com o código.
RSpec.describe PecExternal::Authorize do
  include ActiveSupport::Testing::TimeHelpers
  include CityRequestAuth # test_city_host, usado por signed_pec_path

  let(:city) { timeline_city!(record_mode: "integrated", clinical_record: false, pec: true) }
  let(:unit) { create_unit("UBS Norte").tap { |u| u.update!(cnes: "1234567") } }
  let(:nurse) { screener!(unit).tap { |u| u.professional.update!(cpf: "52998224725") } }
  let(:citizen) { verified_citizen!(141) }

  before { city; pec_settings!; nurse }

  def call(professional: "52998224725", citizen_doc: citizen.cpf, cnes: "1234567", at: Time.current, key: TimelineHelpers::PEC_KEY)
    url = signed_pec_path(professional: professional, citizen: citizen_doc, cnes: cnes, at: at, key: key)
    params = Rack::Utils.parse_query(URI.parse(url).query)
    described_class.call(city: city, url: url, params: params)
  end

  def denied_codes = DomainEvent.where(name: "pec.external_view_denied").order(:occurred_at, :created_at).map { |e| e.payload["reason_code"] }

  it "válida: o profissional, a unidade e a pessoa; evento de abertura só com ids" do
    result = call
    expect(result).to be_ok
    grant = result.payload[:grant]
    expect([ grant.user, grant.unit, grant.person.citizen_ids ]).to eq([ nurse, unit, [ citizen.id ] ])
    expect(DomainEvent.where(name: "pec.external_view_opened").order(:occurred_at, :created_at).last.payload)
      .to eq("user_id" => nurse.id, "unit_id" => unit.id, "patient_id" => nil)
  end

  it "profissional pelo CNS também vale" do
    expect(call(professional: nurse.professional.cns)).to be_ok
  end

  it "cada recusa na ordem, com o código e o evento" do
    expect(call(key: "outra-chave-0123456789").reason).to eq(:pec_signature_invalid)
    expect(call(at: 6.minutes.ago).reason).to eq(:pec_expired)
    # Instantes explícitos: com "agora" e "1 segundo atrás", virar o segundo entre
    # as duas chamadas repetia a mesma URL assinada e caía em pec_replayed.
    first_at = Time.current
    expect(call(cnes: "7654321", at: first_at).reason).to eq(:pec_unit_unknown)
    other_unit = create_unit("UBS Sul").tap { |u| u.update!(cnes: "7654321") }
    expect(call(cnes: other_unit.cnes, at: first_at - 1.second).reason).to eq(:pec_professional_not_linked)
    expect(call(professional: "11144477735").reason).to eq(:pec_professional_not_linked)
    expect(call(citizen_doc: screening_citizen!(142).cpf).reason).to eq(:pec_citizen_not_verified)
    expect(call(citizen_doc: "898001160660003").reason).to eq(:pec_citizen_not_verified)
    expect(denied_codes).to eq(%w[pec_signature_invalid pec_expired pec_unit_unknown pec_professional_not_linked
                                  pec_professional_not_linked pec_citizen_not_verified pec_citizen_not_verified])
  end

  it "sem documento do cidadão (acesso pelo menu): pec_citizen_missing" do
    unsigned = "http://#{test_city_host}/pec/timeline?documento-profissional=52998224725&cnes=1234567&pec_timestamp=#{Time.current.to_i}"
    url = "#{unsigned}&pec_sign=#{OpenSSL::HMAC.hexdigest('SHA256', TimelineHelpers::PEC_KEY, unsigned)}"
    result = described_class.call(city: city, url: url, params: Rack::Utils.parse_query(URI.parse(url).query))
    expect(result.reason).to eq(:pec_citizen_missing)
  end

  it "vínculo encerrado ou usuário desativado: pec_professional_not_linked" do
    nurse.professional.links.active.sole.update!(ended_at: Time.current, ended_by_user: reception!)
    expect(call.reason).to eq(:pec_professional_not_linked)
  end

  it "desligado, fora do modo integrado ou sem configuração: pec_disabled" do
    PecSetting.current.update!(hmac_key: nil, hmac_key_updated_at: nil)
    expect(call.reason).to eq(:pec_disabled)
    pec_settings!
    city.update!(record_mode: "record")
    expect(call.reason).to eq(:pec_disabled)
  end

  it "sessão curta: volta o mesmo grant; vence em 15 min, troca de cidade, vínculo encerrado ou interruptor desligado" do
    grant = call.payload[:grant]
    token = PecExternal::ViewSession.issue(city: city, grant: grant)
    resumed = PecExternal::ViewSession.resume(token, city: city)
    expect([ resumed.user, resumed.unit, resumed.person.citizen_ids ]).to eq([ nurse, unit, [ citizen.id ] ])
    expect(PecExternal::ViewSession.resume("lixo", city: city)).to be_nil
    expect(PecExternal::ViewSession.resume(nil, city: city)).to be_nil
    expect(PecExternal::ViewSession.resume(token, city: City.new(id: SecureRandom.uuid))).to be_nil
    travel_to(16.minutes.from_now) { expect(PecExternal::ViewSession.resume(token, city: city)).to be_nil }
    Platform::Features.set!(city: city, key: "pec_external_view", enabled: false, maintainer: ledi_maintainer!)
    expect(PecExternal::ViewSession.resume(token, city: city)).to be_nil
  end

  it "o grant e o token não expõem CPF, CNS nem chave no inspect" do
    grant = call.payload[:grant]
    token = PecExternal::ViewSession.issue(city: city, grant: grant)
    dump = [ grant.inspect, grant.to_s, token ].join(" ")
    [ citizen.cpf, nurse.professional.cpf, nurse.professional.cns, TimelineHelpers::PEC_KEY ].each do |secret|
      expect(dump).not_to include(secret)
    end
  end
end
