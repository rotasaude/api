require "rails_helper"
require Rails.root.join("lib/fake_lab/runner").to_s

# Contrato §13 (F-21.7): o fake-lab lê as guias do prestador simulado e
# envia um laudo do perfil; com fake_lab desligado, o api responde 403 e
# ele só registra no log. Nunca sobe em produção.
RSpec.describe "FakeLab" do
  before { exam_city!(fake_lab: true) }

  let(:unit) { create_unit("UBS Fake") }
  let(:doctor) { doctor!(unit) }
  let(:item) do
    exam_catalog_item!(sigtap_code: "0202020380", result_fields: [ { "key" => "hb", "label" => "Hemoglobina", "unit" => "g/dL", "loinc" => "718-7" } ])
  end
  let(:provider) do
    exam_provider!(name: "Laboratório Simulado", simulated: true, token: ExamHelpers::FAKE_TOKEN)
      .tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) }
  end
  let(:host) { "#{TEST_CITY_A.slug}.rotasaude.app" }
  let(:client) { FakeLab::Client.new(api_url: "http://#{host}", city_host: host, token: ExamHelpers::FAKE_TOKEN) }

  # O cliente fala HTTP; aqui o "servidor" é o próprio app Rails (WebMock → Rack),
  # no host da cidade de teste (o mesmo dos request specs).
  # WebMock injeta rack.session como Hash puro, o que quebra o middleware de
  # sessão do Rails; o wrapper o remove para o app montar a sua.
  let(:rails_app) do
    lambda do |env|
      env.delete("rack.session")
      env.delete("rack.session.options")
      Rails.application.call(env)
    end
  end
  before { stub_request(:any, /#{Regexp.escape(host)}/).to_rack(rails_app) }

  it "o laudo montado passa no esquema do perfil" do
    schema = JSONSchemer.schema(Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json"))
    sr = { "identifier" => [ { "value" => "K7M2Q9XR4T" } ], "code" => { "coding" => [ { "code" => "0202010503" } ] },
           "subject" => { "identifier" => { "system" => "http://rnds.saude.gov.br/fhir/r4/NamingSystem/cpf", "value" => "52998224725" } } }
    report = FakeLab::Report.build(sr)
    expect(schema.validate(report).to_a).to eq([])
    expect(Base64.strict_decode64(report.dig("presentedForm", 0, "data"))).to start_with("%PDF-")
    expect(report.to_json).not_to include("Luiz", "Maria")
  end

  it "outro código SIGTAP vira um único valueString que passa no esquema" do
    schema = JSONSchemer.schema(Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json"))
    sr = { "identifier" => [ { "value" => "K7M2Q9XR4T" } ], "code" => { "coding" => [ { "code" => "0202030000" } ] },
           "subject" => { "identifier" => { "system" => "http://rnds.saude.gov.br/fhir/r4/NamingSystem/cpf", "value" => "52998224725" } } }
    report = FakeLab::Report.build(sr)
    expect(report["contained"].map { |o| o["valueString"] }).to eq([ "Resultado simulado — sem validade" ])
    expect(schema.validate(report).to_a).to eq([])
  end

  it "um ciclo: pede as guias, envia o laudo, o exame fica com resultado; de novo não duplica" do
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor, sigtap_code: item.sigtap_code)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.hour.from_now.iso8601, scheduled_place: "Lab simulado" })
    log = StringIO.new
    logger = Logger.new(log)
    expect(FakeLab::Runner.tick(client: client, logger: logger)).to eq([ [ order.short_code, 201 ] ])
    expect(order.reload.status).to eq("resulted")
    expect(order.result).to have_attributes(source: "fhir", laboratory_name: "Laboratório Simulado")
    expect(log.string).not_to include(ExamHelpers::FAKE_TOKEN, order.patient.cpf)
    expect(FakeLab::Runner.tick(client: client, logger: logger)).to eq([])
  end

  it "fake_lab desligado: 403 e só log" do
    provider
    Platform::Features.set!(city: Current.city, key: "fake_lab", enabled: false, maintainer: ledi_maintainer!)
    log = StringIO.new
    expect(FakeLab::Runner.tick(client: client, logger: Logger.new(log))).to eq([])
    expect(log.string).to include("fake_lab desligado")
  end

  it "nunca em produção" do
    env = { "RAILS_ENV" => "production" }
    out = IO.popen(env, [ "ruby", Rails.root.join("lib/fake_lab/run.rb").to_s ], err: [ :child, :out ], &:read)
    expect(out).to include("fake-lab nunca sobe em produção")
  end
end
